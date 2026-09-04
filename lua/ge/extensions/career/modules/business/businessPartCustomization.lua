local M = {}

M.dependencies = {
  'career_career',
  'core_vehicles',
  'core_jobsystem',
  'career_modules_business_businessComputer',
  'career_modules_business_businessPartConditions',
}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local currentSession = nil
local ensureActiveSession
local emergencyRestoreBusinessVehicle

local function resetCurrentSession()
  currentSession = nil
end

local function sessionMatches(businessId, vehicleId)
  if not currentSession then
    return false
  end
  if tostring(currentSession.businessId) ~= tostring(businessId) then
    return false
  end
  if vehicleId and tostring(currentSession.vehicleId) ~= tostring(vehicleId) then
    return false
  end
  return true
end

local function getActiveSession(businessId)
  if sessionMatches(businessId) then
    return currentSession
  end
  return nil
end

local function getPartSupplierDiscountMultiplier(businessId)
  local bc = career_modules_business_businessComputer
  if bc and bc.getPartSupplierDiscountMultiplier then
    return bc.getPartSupplierDiscountMultiplier(businessId)
  end
  return 1.0
end

local function isPersonalVehicleId(vehicleId)
  if not vehicleId then
    return false
  end
  return tostring(vehicleId):sub(1, 9) == "personal_"
end

local function getSpawnedIdFromPersonalVehicleId(vehicleId)
  if not isPersonalVehicleId(vehicleId) then
    return nil
  end
  return tonumber(tostring(vehicleId):sub(10))
end

local function getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
  local bc = career_modules_business_businessComputer
  if bc and bc.getInventoryIdFromPersonalVehicleId then
    return bc.getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
  end
  return nil
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

local function flattenPartsTree(tree)
  local result = {}
  if not tree then
    return result
  end

  if tree.chosenPartName then
    result[tree.path] = tree.chosenPartName
  end

  if tree.children then
    for slotName, childNode in pairs(tree.children) do
      tableMerge(result, flattenPartsTree(childNode))
    end
  end

  return result
end

local function partListFingerprint(partList)
  if not partList or not next(partList) then
    return ""
  end
  local keys = {}
  for slotPath in pairs(partList) do
    keys[#keys + 1] = slotPath
  end
  table.sort(keys)
  local parts = {}
  for _, slotPath in ipairs(keys) do
    parts[#parts + 1] = slotPath .. "=" .. tostring(partList[slotPath])
  end
  return table.concat(parts, "|")
end

local function resolveBaselineVehicleConfig(vehicle, vehicleData, isPersonal, inventoryOnly)
  if not vehicle then
    return nil
  end

  local originalConfig = nil
  if isPersonal then
    if vehicleData and vehicleData.config and vehicleData.config.partsTree then
      originalConfig = vehicleData.config
    elseif vehicle.config and vehicle.config.partsTree then
      originalConfig = vehicle.config
    end
  else
    local invConfig = vehicle.config
    local liveConfig = vehicleData and vehicleData.config or nil
    if inventoryOnly then
      if invConfig and invConfig.partsTree then
        originalConfig = invConfig
      elseif liveConfig and liveConfig.partsTree then
        originalConfig = liveConfig
      end
    else
      local invParts = (invConfig and invConfig.partsTree) and flattenPartsTree(invConfig.partsTree) or {}
      local liveParts = (liveConfig and liveConfig.partsTree) and flattenPartsTree(liveConfig.partsTree) or {}
      local liveLoadable = liveConfig and liveConfig.partsTree and liveConfig.partsTree.chosenPartName and
        liveConfig.partsTree.chosenPartName ~= ""

      if liveLoadable and partListFingerprint(liveParts) ~= partListFingerprint(invParts) then
        originalConfig = liveConfig
      elseif invConfig and invConfig.partsTree then
        originalConfig = invConfig
      elseif liveConfig and liveConfig.partsTree then
        originalConfig = liveConfig
      end
    end
  end

  return originalConfig
end

local function resolveRestoreBaseline(businessId, vehicleId, session)
  local isPersonal = isPersonalVehicleId(vehicleId)
  local vehicle = nil
  if isPersonal then
    vehicle = getPersonalVehicleData(vehicleId, businessId)
  else
    vehicle = career_modules_business_businessInventory and
      career_modules_business_businessInventory.getVehicleById and
      career_modules_business_businessInventory.getVehicleById(businessId, vehicleId) or nil
  end

  local restoreConfig = nil
  local restorePartConditions = nil
  if vehicle and vehicle.config and vehicle.config.partsTree then
    restoreConfig = deepcopy(vehicle.config)
    restorePartConditions = deepcopy(vehicle.partConditions or {})
  elseif session and session.initial and session.initial.config then
    restoreConfig = deepcopy(session.initial.config)
    restorePartConditions = deepcopy(session.initial.partConditions or {})
  end

  return restoreConfig, restorePartConditions
end

local function refreshSessionInitialFromSavedVehicle(businessId, vehicleId, inventoryOnly)
  if not businessId or not vehicleId then
    return false
  end

  local isPersonal = isPersonalVehicleId(vehicleId)
  local vehicle = nil
  if isPersonal then
    vehicle = getPersonalVehicleData(vehicleId, businessId)
  else
    vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  end

  if not vehicle or not vehicle.vehicleConfig then
    return false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  local vehicleData = nil
  if vehObj and not inventoryOnly then
    vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
  end

  local originalConfig = resolveBaselineVehicleConfig(vehicle, vehicleData, isPersonal, inventoryOnly == true)
  if not originalConfig then
    return false
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  local session = ensureActiveSession(businessId, vehicleId)
  if not session then
    return false
  end

  session.initial.config = deepcopy(originalConfig)
  session.initial.partList = flattenPartsTree(originalConfig.partsTree or {})
  session.initial.partConditions = deepcopy(vehicle.partConditions or {})
  session.initial.vars = deepcopy(vehicle.vars or {})
  session.initial.model = modelKey
  return true
end

local function sessionPreviewDiffersFromInitial(session)
  if not session or not session.initial or not session.preview then
    return false
  end

  local initialParts = session.initial.partList or flattenPartsTree(session.initial.config.partsTree or {})
  local previewParts = session.preview.partList or flattenPartsTree(session.preview.config.partsTree or {})
  return partListFingerprint(initialParts) ~= partListFingerprint(previewParts)
end

local function liveVehicleMatchesBaseline(vehObj, baselineParts)
  if not vehObj or not baselineParts then
    return false
  end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
  if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
    return false
  end

  local liveParts = flattenPartsTree(vehicleData.config.partsTree or {})
  return partListFingerprint(liveParts) == partListFingerprint(baselineParts)
end

local function getNodeFromSlotPath(tree, path)
  if not tree or not path then
    return nil
  end

  if path == "/" then
    return tree
  end

  local segments = {}
  for segment in string.gmatch(path, "[^/]+") do
    table.insert(segments, segment)
  end

  local currentNode = tree
  for _, segment in ipairs(segments) do
    if currentNode.children and currentNode.children[segment] then
      currentNode = currentNode.children[segment]
    else
      return nil
    end
  end

  return currentNode
end

local function storeFuelLevels(vehObj, callback)
  if not vehObj then
    if callback then
      callback()
    end
    return
  end

  core_vehicleBridge.requestValue(vehObj, function(data)
    local storedFuelLevels = {}
    if data and data[1] then
      for _, tank in ipairs(data[1]) do
        if tank.energyType ~= "n2o" then
          storedFuelLevels[tank.name] = {
            currentEnergy = tank.currentEnergy,
            maxEnergy = tank.maxEnergy,
            energyType = tank.energyType,
            relativeFuel = tank.maxEnergy > 0 and (tank.currentEnergy / tank.maxEnergy) or 0
          }
        end
      end
    end
    if callback then
      callback(storedFuelLevels)
    end
  end, 'energyStorage')
end

local function restoreFuelLevels(vehObj, storedFuelLevels)
  if not vehObj or not storedFuelLevels or not next(storedFuelLevels) then
    return
  end

  core_vehicleBridge.requestValue(vehObj, function(data)
    if not data or not data[1] then
      return
    end

    for _, tank in ipairs(data[1]) do
      local stored = storedFuelLevels[tank.name]
      if stored and stored.energyType == tank.energyType then
        local newFuelAmount = math.min(stored.currentEnergy, tank.maxEnergy)
        if tank.maxEnergy > stored.maxEnergy then
          newFuelAmount = tank.maxEnergy * stored.relativeFuel
        end

        local minFuel = tank.maxEnergy * 0.05
        newFuelAmount = math.max(newFuelAmount, minFuel)

        core_vehicleBridge.executeAction(vehObj, 'setEnergyStorageEnergy', tank.name, newFuelAmount)
      end
    end
  end, 'energyStorage')
end

-- ignoreDynoGate: allow power read when dyno skill locked (racing team); tuning shop still gates unless true.
local function requestVehiclePowerWeight(vehObj, businessId, vehicleId, ignoreDynoGate)
  if not vehObj or not businessId or not vehicleId then
    return
  end

  if not ignoreDynoGate and career_modules_business_businessSkillTree then
    local businessType
    if career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects then
      local normalizedBusinessId = tostring(businessId)
      for currentBusinessType, _ in pairs(career_modules_business_businessManager.getAllBusinessObjects() or {}) do
        if career_modules_business_businessManager.getPurchasedBusinesses then
          local purchased = career_modules_business_businessManager.getPurchasedBusinesses(currentBusinessType) or {}
          if purchased[businessId] or purchased[normalizedBusinessId] then
            businessType = currentBusinessType
            break
          end
        end
      end
    end

    local dynoLevel = 0
    if businessType == "tuningShop" then
      dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "dyno") or 0
    elseif businessType == "racingTeam" then
      dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "qol", "dyno") or 0
    end
    if dynoLevel == 0 and businessType ~= "racingTeam" then
      return
    end
  end

  local cacheKey = businessId .. "_" .. tostring(vehicleId)
  local requestId = cacheKey .. "_" .. tostring(os.clock())

  vehObj:queueLuaCommand([[
    local engine = powertrain.getDevicesByCategory("engine")[1]
    local stats = obj:calcBeamStats()
    if engine and stats then
      local power = engine.maxPower
      local weight = stats.total_weight
      local torque = nil
      if v and v.data and v.data.mainEngine and v.data.mainEngine.torque then
         torque = serialize(v.data.mainEngine.torque)
      end
      if power and weight and weight > 0 then
        obj:queueGameEngineLua("career_modules_business_businessPartCustomization.onPowerWeightReceived(']] .. requestId ..
                           [[', " .. power .. ", " .. weight .. ", " .. (torque or "nil") .. ")")
      end
    end
  ]])
end

local function createOrUpdatePartsTreeNode(partsTree, partName, slotPath)
  if not partsTree or not slotPath then
    return false
  end

  local node = getNodeFromSlotPath(partsTree, slotPath)
  if node then
    if partName == "" or not partName then
      node.chosenPartName = ""
      node.emptyPlaceholder = true
    else
      node.chosenPartName = partName
      node.emptyPlaceholder = nil
    end
    return true
  end

  local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
  local parentNode = getNodeFromSlotPath(partsTree, parentPath)
  if parentNode then
    if not parentNode.children then
      parentNode.children = {}
    end
    local slotName = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or ""
    if slotName and slotName ~= "" then
      local chosenPartName = (partName == "" or not partName) and "" or partName
      parentNode.children[slotName] = {
        chosenPartName = chosenPartName,
        path = slotPath,
        children = {},
        suitablePartNames = chosenPartName ~= "" and {chosenPartName} or {},
        unsuitablePartNames = {},
        decisionMethod = "user",
        emptyPlaceholder = (partName == "" or not partName) and true or nil
      }
      return true
    end
  end

  return false
end

local function getSlotPathDepth(slotPath)
  if not slotPath then
    return 0
  end
  local depth = 0
  for _ in string.gmatch(slotPath, "[^/]+") do
    depth = depth + 1
  end
  return depth
end

local function applyPartsBySlotPath(partsTree, partsBySlotPath)
  if not partsTree or not partsBySlotPath then
    return
  end

  local orderedPaths = {}
  for slotPath, part in pairs(partsBySlotPath) do
    if slotPath and part and part.partName and part.partName ~= "" then
      table.insert(orderedPaths, slotPath)
    end
  end

  table.sort(orderedPaths, function(a, b)
    local depthA = getSlotPathDepth(a)
    local depthB = getSlotPathDepth(b)
    if depthA ~= depthB then
      return depthA < depthB
    end
    return a < b
  end)

  local pending = {}
  for _, slotPath in ipairs(orderedPaths) do
    local part = partsBySlotPath[slotPath]
    local applied = createOrUpdatePartsTreeNode(partsTree, part.partName, part.slotPath or slotPath)
    if not applied then
      pending[slotPath] = part
    end
  end

  if next(pending) then
    local progressed = true
    while progressed and next(pending) do
      progressed = false
      for slotPath, part in pairs(pending) do
        if createOrUpdatePartsTreeNode(partsTree, part.partName, part.slotPath or slotPath) then
          pending[slotPath] = nil
          progressed = true
        end
      end
    end
  end
end

local function getPartConditionApplyOpts(config)
  local partsTree = config and config.partsTree
  if not partsTree or not career_modules_business_businessPartConditions then
    return nil
  end
  return {
    validPartKeys = career_modules_business_businessPartConditions.collectPartConditionKeysFromPartsTree(partsTree),
  }
end

local function finishPartReplaceConditionHandling(businessId, vehicleId, vehObj, config, afterDone)
  local vehicle = career_modules_business_businessInventory and
    career_modules_business_businessInventory.getVehicleById and
    career_modules_business_businessInventory.getVehicleById(businessId, vehicleId) or nil

  career_modules_business_businessPartConditions.reinitializePartConditionsFromVehicle(vehObj, vehicle,
    function(freshConditions)
      if sessionMatches(businessId, vehicleId) and currentSession then
        local fresh = deepcopy(freshConditions or {})
        currentSession.preview.partConditions = fresh
        currentSession.initial.partConditions = fresh
      end
      if vehicle and freshConditions and career_modules_business_businessInventory and
          career_modules_business_businessInventory.updateVehicle then
        career_modules_business_businessInventory.updateVehicle(businessId, vehicleId, {
          partConditions = deepcopy(freshConditions),
        })
        if career_modules_business_businessInventory.getPulledOutVehicles then
          local pulledVehicles = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
          local targetId = tonumber(vehicleId) or vehicleId
          for _, pulled in ipairs(pulledVehicles) do
            local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
            if pulledId == targetId then
              pulled.partConditions = deepcopy(freshConditions)
            end
          end
        end
      end
      if sessionMatches(businessId, vehicleId) and currentSession and currentSession.isPersonal and
          currentSession.inventoryId and freshConditions and career_modules_inventory then
        local inventoryVehicles = career_modules_inventory.getVehicles()
        local inventoryVehicle = inventoryVehicles and inventoryVehicles[currentSession.inventoryId]
        if inventoryVehicle then
          inventoryVehicle.partConditions = deepcopy(freshConditions)
          if career_modules_inventory.setVehicleDirty then
            career_modules_inventory.setVehicleDirty(currentSession.inventoryId)
          end
        end
      end
      if afterDone then
        afterDone(freshConditions)
      end
    end)
end

local function replaceVehicleWithFuelHandling(vehObj, modelKey, config, beforeRestoreCallback, afterRestoreCallback)
  if not vehObj or not modelKey or not config then
    if afterRestoreCallback then
      afterRestoreCallback()
    end
    return
  end

  local vehId = vehObj:getID()
  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {
      spawnWithEngineRunning = false
    }
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)

    local spawnOptions = {}
    spawnOptions.config = config
    spawnOptions.keepOtherVehRotation = true

    core_vehicles.replaceVehicle(modelKey, spawnOptions, vehObj)

    if beforeRestoreCallback then
      beforeRestoreCallback()
    end

    core_vehicleBridge.requestValue(vehObj, function()
      restoreFuelLevels(vehObj, storedFuelLevels)
      if afterRestoreCallback then
        afterRestoreCallback()
      end
    end, 'ping')
  end)
end

local function getPersonalVehicleData(vehicleId, businessId)
  local bc = career_modules_business_businessComputer
  if bc and bc.getPersonalVehicleData then
    return bc.getPersonalVehicleData(vehicleId, businessId)
  end
  return nil
end

local function initializePreviewVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  local vehicle = nil
  local isPersonal = isPersonalVehicleId(vehicleId)

  if isPersonal then
    vehicle = getPersonalVehicleData(vehicleId, businessId)
  else
    vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  end

  if not vehicle or not vehicle.vehicleConfig then
    return false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end

  local vehId = vehObj:getID()

  if isPersonal then
    local partConditions = vehicle.partConditions or {}
    career_modules_business_businessPartConditions.applyInitPartConditions(
      vehObj, partConditions, nil, nil, nil, getPartConditionApplyOpts(vehicle.config))
  end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)

  if not vehicleData then
    return false
  end

  local originalConfig = resolveBaselineVehicleConfig(vehicle, vehicleData, isPersonal)

  if not originalConfig then
    return false
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key

  local initialState = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    vars = deepcopy(vehicle.vars or {}),
    model = modelKey,
    vehicleId = vehicleId,
    partsNiceName = {},
    isPersonal = isPersonal,
    inventoryId = isPersonal and vehicle.inventoryId or nil
  }

  local previewState = {
    config = deepcopy(originalConfig),
    partList = flattenPartsTree(originalConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }

  local slotData = {}
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  local partsNiceName = {}
  for partName, partInfo in pairs(availableParts) do
    local desc = partInfo.description
    partsNiceName[partName] = type(desc) == "table" and desc.description or desc
    if partInfo.slotInfoUi then
      for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
        local path = "/" .. slotName .. "/"
        slotData[path] = slotInfo
      end
    end
  end
  initialState.partsNiceName = partsNiceName

  currentSession = {
    businessId = businessId,
    vehicleId = vehicleId,
    initial = initialState,
    preview = previewState,
    slotData = slotData,
    powerWeight = nil,
    operationInProgress = false,
    isPersonal = isPersonal,
    inventoryId = isPersonal and vehicle.inventoryId or nil
  }

  return true
end

ensureActiveSession = function(businessId, vehicleId)
  local session = getActiveSession(businessId)
  if session and (not vehicleId or tostring(session.vehicleId) == tostring(vehicleId)) then
    return session
  end
  if vehicleId and initializePreviewVehicle(businessId, vehicleId) then
    return currentSession
  end
  return nil
end

local function getActiveSessionConfig(session)
  if not session then
    return nil
  end
  local prev = session.preview and session.preview.config
  if prev and prev.partsTree then
    return prev
  end
  local ini = session.initial and session.initial.config
  if ini and ini.partsTree then
    return ini
  end
  return prev or ini
end

local function mergePreviewTuningVarsIntoConfig(destConfig, session)
  if not destConfig or not session or not session.preview or not session.preview.config then
    return
  end
  local pv = session.preview.config.vars
  if pv then
    destConfig.vars = deepcopy(pv)
  end
end

local function resetVehicleToOriginal(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  refreshSessionInitialFromSavedVehicle(businessId, vehicleId, true)

  local session = ensureActiveSession(businessId, vehicleId)
  if not session or not session.initial or not session.initial.config then
    return false
  end
  if session.operationInProgress then
    local liveObj = getBusinessVehicleObject(businessId, vehicleId)
    if liveObj then
      return false
    end
    session.operationInProgress = false
  end

  local baselineParts = session.initial.partList or flattenPartsTree(session.initial.config.partsTree or {})
  local previewDiffers = sessionPreviewDiffersFromInitial(session)

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    local restoreConfig, restorePartConditions = resolveRestoreBaseline(businessId, vehicleId, session)
    vehObj = emergencyRestoreBusinessVehicle(businessId, vehicleId, restoreConfig, restorePartConditions)
  end
  if not vehObj then
    return false
  end

  if not previewDiffers and liveVehicleMatchesBaseline(vehObj, baselineParts) then
    local modelKey = session.initial.model
    session.preview = {
      config = deepcopy(session.initial.config),
      partList = deepcopy(baselineParts),
      partConditions = deepcopy(session.initial.partConditions or {}),
      model = modelKey
    }
    return true
  end

  session.operationInProgress = true

  local baselineConfig = deepcopy(session.initial.config)
  local modelKey = session.initial.model
  local vehicle = career_modules_business_businessInventory and
                    career_modules_business_businessInventory.getVehicleById and
                    career_modules_business_businessInventory.getVehicleById(businessId, vehicleId) or nil

  if not modelKey and vehicle and vehicle.vehicleConfig then
    modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  end
  if not modelKey then
    session.operationInProgress = false
    return false
  end

  local baselinePartConditions = deepcopy(session.initial.partConditions or {})
  if (not next(baselinePartConditions)) and vehicle and vehicle.partConditions then
    baselinePartConditions = deepcopy(vehicle.partConditions)
  end

  core_jobsystem.create(function(job)
    job.sleep(0.5)

    replaceVehicleWithFuelHandling(vehObj, modelKey, baselineConfig, function()
      if baselinePartConditions and next(baselinePartConditions) then
        career_modules_business_businessPartConditions.applyInitPartConditions(
          vehObj, baselinePartConditions, nil, nil, nil, getPartConditionApplyOpts(baselineConfig))
      end
    end, function()
      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
      session.operationInProgress = false
    end)

    session.preview = {
      config = deepcopy(baselineConfig),
      partList = flattenPartsTree(baselineConfig.partsTree or {}),
      partConditions = deepcopy(baselinePartConditions or {}),
      model = modelKey
    }
  end)

  return true
end

local function applyPartsToVehicle(businessId, vehicleId, parts)
  if not businessId or not vehicleId or not parts then
    return false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return false
  end

  local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
  if not modelKey then
    return false
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session then
    return false
  end

  local initialVehicle = session.initial
  if not initialVehicle or not initialVehicle.config then
    return false
  end

  local completeConfig = deepcopy(initialVehicle.config)
  mergePreviewTuningVarsIntoConfig(completeConfig, session)

  local partsBySlotPath = {}
  for _, part in ipairs(parts) do
    if part.partName and part.slotPath then
      partsBySlotPath[part.slotPath] = {
        partName = part.partName,
        slotPath = part.slotPath
      }
    end
  end
  applyPartsBySlotPath(completeConfig.partsTree, partsBySlotPath)

  session.preview = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(vehicle.partConditions or {}),
    model = modelKey
  }

  replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig, nil, function()
    finishPartReplaceConditionHandling(businessId, vehicleId, vehObj, completeConfig, function()
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
    end)
  end)

  return true
end

local function buildPartsTreeFromCart(businessId, parts)
  local session = getActiveSession(businessId)
  if not session or not session.initial or not session.initial.config then
    return {}
  end

  local baselineConfig = session.initial.config
  if not baselineConfig or not baselineConfig.partsTree then
    return {}
  end

  local partsTree = deepcopy(baselineConfig.partsTree)

  if parts and #parts > 0 then
    local partsBySlotPath = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath then
        partsBySlotPath[part.slotPath] = {
          partName = part.partName,
          slotPath = part.slotPath
        }
      end
    end
    applyPartsBySlotPath(partsTree, partsBySlotPath)
  end

  return partsTree
end

local function getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
  if not businessId or not vehicleId or not partName or not slotPath then
    return {}
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return {}
  end

  local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
  if not jbeamData or not jbeamData.slotInfoUi then
    return {}
  end

  local requiredParts = {}
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)

  local function getDefaultPartName(jbeamData, slotName)
    if jbeamData.slots2 then
      for _, slot in ipairs(jbeamData.slots2) do
        if slot.name == slotName and slot.default and slot.default ~= "" then
          return slot.default
        end
      end
    end
    return nil
  end

  for slotName, slotInfo in pairs(jbeamData.slotInfoUi) do
    local childPath = slotPath .. slotName .. "/"

    local childNode = getNodeFromSlotPath(currentPartsTree, childPath)
    local hasPart = childNode and childNode.chosenPartName and childNode.chosenPartName ~= ""

    local partFits = false
    if hasPart then
      local existingPartData = jbeamIO.getPart(vehicleData.ioCtx, childNode.chosenPartName)
      if existingPartData and jbeamSlotSystem.partFitsSlot(existingPartData, slotInfo) then
        partFits = true
      end
    end

    if not hasPart or not partFits then
      local defaultPartName = getDefaultPartName(jbeamData, slotName)
      if defaultPartName then
        local requiredPart = {
          partName = defaultPartName,
          slotPath = childPath,
          slotName = slotName,
          partNiceName = availableParts[defaultPartName] or defaultPartName,
          value = 0
        }
        table.insert(requiredParts, requiredPart)

        local childTree = childNode or {
          path = childPath,
          children = {}
        }
        local nestedRequired = getRequiredPartsForPart(businessId, vehicleId, defaultPartName, childPath, childTree)
        for _, nestedPart in ipairs(nestedRequired) do
          table.insert(requiredParts, nestedPart)
        end
      end
    end
  end

  return requiredParts
end

local function getNeededAdditionalParts(businessId, vehicleId, parts, baselineTree, currentCart)
  if not businessId or not vehicleId or not parts then
    return parts, false
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return parts, false
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return parts, false
  end

  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)

  local combinedSlotToPartMap = {}

  local function addBaselineParts(tree, parentPath)
    if not tree then
      return
    end
    if tree.chosenPartName and tree.path then
      combinedSlotToPartMap[tree.path] = {
        name = tree.chosenPartName,
        containingSlot = tree.path,
        slot = tree.path:match("/([^/]+)/$") or ""
      }
    end
    if tree.children then
      for slotName, childNode in pairs(tree.children) do
        addBaselineParts(childNode, childNode.path or (parentPath .. slotName .. "/"))
      end
    end
  end
  addBaselineParts(baselineTree, "/")

  if currentCart then
    for _, item in ipairs(currentCart) do
      if item.type == 'part' and item.partName and item.slotPath then
        combinedSlotToPartMap[item.slotPath] = {
          name = item.partName,
          containingSlot = item.slotPath,
          slot = item.slotPath:match("/([^/]+)/$") or ""
        }
      end
    end
  end

  for slotPath, part in pairs(parts) do
    combinedSlotToPartMap[slotPath] = deepcopy(part)
  end

  for path, part in pairs(combinedSlotToPartMap) do
    local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)
    if jbeamData then
      part.slotType = jbeamData.slotType
    end
  end

  local addedParts = false
  local resultParts = deepcopy(parts)

  local function getDefaultPartName(jbeamData, slotName)
    if jbeamData and jbeamData.slots2 then
      for _, slot in ipairs(jbeamData.slots2) do
        if slot.name == slotName and slot.default and slot.default ~= "" then
          return slot.default
        end
      end
    end
    return nil
  end

  for slotPath, part in pairs(parts) do
    if part.description and part.description.slotInfoUi then
      for slotName, slotInfo in pairs(part.description.slotInfoUi) do
        local childPath = slotPath .. slotName .. "/"

        local existingPart = combinedSlotToPartMap[childPath]
        local partFits = false
        if existingPart then
          partFits = jbeamSlotSystem.partFitsSlot(existingPart, slotInfo)
        end

        if not existingPart or not partFits then
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, part.name)

          local fittingPart = nil
          local partNameToGenerate = getDefaultPartName(jbeamData, slotName)
          if partNameToGenerate then
            local defaultJbeamData = jbeamIO.getPart(vehicleData.ioCtx, partNameToGenerate)
            if defaultJbeamData then
              fittingPart = {
                name = partNameToGenerate,
                containingSlot = childPath,
                slot = slotName,
                description = defaultJbeamData,
                vehicleModel = part.vehicleModel
              }
            end
          end

          if fittingPart then
            resultParts[childPath] = fittingPart
            addedParts = true

            combinedSlotToPartMap[childPath] = fittingPart

            if slotInfo and not slotInfo.coreSlot then
              fittingPart.sourcePart = true
            end
          end
        end
      end
    end
  end

  return resultParts, addedParts
end

local function getAllRequiredParts(businessId, vehicleId, parts, cartParts)
  if not businessId or not vehicleId or not parts then
    return {}
  end

  local currentPartsTree = buildPartsTreeFromCart(businessId, cartParts)

  local allRequiredParts = {}
  local processedParts = {}
  local requiredPartsBySlotPath = {}

  local function processPart(partName, slotPath)
    local key = partName .. "_" .. slotPath
    if processedParts[key] then
      return
    end
    processedParts[key] = true

    local required = getRequiredPartsForPart(businessId, vehicleId, partName, slotPath, currentPartsTree)
    for _, reqPart in ipairs(required) do
      local reqKey = reqPart.partName .. "_" .. reqPart.slotPath
      if not processedParts[reqKey] then
        table.insert(allRequiredParts, reqPart)
        requiredPartsBySlotPath[reqPart.slotPath] = {
          partName = reqPart.partName,
          slotPath = reqPart.slotPath
        }
        applyPartsBySlotPath(currentPartsTree, requiredPartsBySlotPath)
        processPart(reqPart.partName, reqPart.slotPath)
      end
    end
  end

  for _, part in ipairs(parts) do
    if part.partName and part.slotPath then
      processPart(part.partName, part.slotPath)
    end
  end

  return allRequiredParts
end

local function getSlotInfoForPath(session, slotPath, vehicleData)
  if not session or not slotPath or slotPath == "" then
    return nil
  end
  local slotData = session.slotData or {}
  if slotData[slotPath] then
    return slotData[slotPath]
  end
  local slotName = slotPath:match("/([^/]+)/$") or ""
  local nameMatch = nil
  local nameMatchCount = 0
  for path, info in pairs(slotData) do
    local pathSlotName = path:match("/([^/]+)/$") or ""
    if pathSlotName == slotName then
      nameMatch = info
      nameMatchCount = nameMatchCount + 1
      if nameMatchCount > 1 then
        nameMatch = nil
        break
      end
    end
  end
  if nameMatchCount == 1 then
    return nameMatch
  end
  if not vehicleData or not vehicleData.ioCtx then
    return nil
  end
  local baselineCfg = session.initial and session.initial.config
  if not baselineCfg or not baselineCfg.partsTree then
    return nil
  end
  local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
  local parentNode = getNodeFromSlotPath(baselineCfg.partsTree, parentPath)
  if parentNode and parentNode.chosenPartName then
    local parentJbeamData = jbeamIO.getPart(vehicleData.ioCtx, parentNode.chosenPartName)
    if parentJbeamData and parentJbeamData.slotInfoUi and parentJbeamData.slotInfoUi[slotName] then
      return parentJbeamData.slotInfoUi[slotName]
    end
  end
  return nil
end

local function slotAllowsRemoval(session, slotPath, vehicleData)
  if not session or not session.initial or not session.initial.partList then
    return false
  end
  local baselinePartName = session.initial.partList[slotPath]
  if not baselinePartName or baselinePartName == "" then
    return false
  end
  local slotInfo = getSlotInfoForPath(session, slotPath, vehicleData)
  if slotInfo and slotInfo.coreSlot then
    return false
  end
  return true
end

local function cartHasBlockedCoreRemovals(parts, session, vehicleData)
  if not parts or not session then
    return false
  end
  for _, part in ipairs(parts) do
    if part.emptyPlaceholder or part.partName == "" or not part.partName then
      if not slotAllowsRemoval(session, part.slotPath or "", vehicleData) then
        return true
      end
    end
  end
  return false
end

local function resolveBusinessTypeForVehicle(businessId)
  if career_modules_business_businessComputer and career_modules_business_businessComputer.getBusinessTypeForId then
    return career_modules_business_businessComputer.getBusinessTypeForId(businessId) or "tuningShop"
  end
  return "tuningShop"
end

emergencyRestoreBusinessVehicle = function(businessId, vehicleId, baselineConfig, baselinePartConditions)
  if isPersonalVehicleId(vehicleId) then
    return nil
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.emergencyRespawnPulledOutVehicle then
    return nil
  end
  return inv.emergencyRespawnPulledOutVehicle(
    resolveBusinessTypeForVehicle(businessId),
    businessId,
    vehicleId,
    baselineConfig,
    baselinePartConditions
  )
end

local function applyCartPartsToVehicle(businessId, vehicleId, parts, onComplete)
  local function finish(ok)
    if onComplete then
      onComplete(ok == true)
    end
  end

  if not businessId or not vehicleId then
    finish(false)
    return false
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session then
    finish(false)
    return false
  end
  if session.operationInProgress then
    finish(false)
    return false
  end

  session.operationInProgress = true

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    local restoreConfig, restorePartConditions = resolveRestoreBaseline(businessId, vehicleId, session)
    vehObj = emergencyRestoreBusinessVehicle(businessId, vehicleId, restoreConfig, restorePartConditions)
  end
  if not vehObj then
    session.operationInProgress = false
    finish(false)
    return false
  end

  local initialVehicle = session.initial
  if not initialVehicle or not initialVehicle.config then
    session.operationInProgress = false
    finish(false)
    return false
  end

  local rollbackConfig = deepcopy(initialVehicle.config)
  local completeConfig = deepcopy(initialVehicle.config)
  mergePreviewTuningVarsIntoConfig(completeConfig, session)

  local function clearChildParts(node, path)
    if not node or not node.children then
      return
    end
    for slotName, childNode in pairs(node.children) do
      local childPath = path .. slotName .. "/"
      childNode.chosenPartName = ""
      if childNode.children then
        clearChildParts(childNode, childPath)
      end
    end
  end

  local function notifyCartApplyFailed(message)
    if ui_message then
      ui_message(message, 6, "Business Computer", "error")
    end
    if guihooks then
      guihooks.trigger('businessComputer:onPartCartApplyFailed', {
        businessId = businessId,
        vehicleId = vehicleId,
        message = message
      })
    end
  end

  local function finishRestoreAfterFailedReplace(message)
    replaceVehicleWithFuelHandling(vehObj, initialVehicle.model, rollbackConfig, nil, function()
      session.preview = {
        config = deepcopy(rollbackConfig),
        partList = flattenPartsTree(rollbackConfig.partsTree or {}),
        partConditions = deepcopy(initialVehicle.partConditions or {}),
        model = initialVehicle.model
      }
      session.operationInProgress = false
      notifyCartApplyFailed(message)
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      finish(false)
    end)
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)

  if parts and #parts > 0 and cartHasBlockedCoreRemovals(parts, session, vehicleData) then
    session.operationInProgress = false
    notifyCartApplyFailed("Core parts cannot be removed from this vehicle.")
    finish(false)
    return false
  end

  if parts and #parts > 0 then
    local removalMarkers = {}
    local partsToApply = {}

    for _, part in ipairs(parts) do
      if part.emptyPlaceholder or (part.partName == "" or not part.partName) then
        removalMarkers[part.slotPath] = part
      elseif part.partName and part.slotPath then
        table.insert(partsToApply, {
          partName = part.partName,
          slotPath = part.slotPath
        })
      end
    end

    for slotPath, removalMarker in pairs(removalMarkers) do
      local node = getNodeFromSlotPath(completeConfig.partsTree, slotPath)
      if node then
        node.chosenPartName = ""
        node.emptyPlaceholder = true
        clearChildParts(node, slotPath)
      end
    end

    local requiredParts = getAllRequiredParts(businessId, vehicleId, partsToApply, parts)

    local allParts = {}
    for _, part in ipairs(parts) do
      if part.partName and part.slotPath and part.partName ~= "" then
        allParts[part.slotPath] = part
      end
    end

    local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
    local vehicleModel = nil
    if vehObj then
      vehicleModel = vehObj:getJBeamFilename()
    end

    for _, reqPart in ipairs(requiredParts) do
      if not allParts[reqPart.slotPath] then
        local reqPartPrice = reqPart.value or 0

        if vehObj then
          local vehId = vehObj:getID()
          local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
          if vehicleData and vehicleData.ioCtx then
            local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, reqPart.partName)
            if jbeamData then
              local baseValue = jbeamData.information and jbeamData.information.value or 100

              if career_modules_valueCalculator then
                local partForValueCalc = {
                  name = reqPart.partName,
                  value = baseValue,
                  partCondition = {
                    integrityValue = 1,
                    odometer = 0,
                    visualValue = 1
                  },
                  vehicleModel = vehicleModel
                }
                reqPartPrice = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) -
                                          0.01, 0)
              else
                reqPartPrice = baseValue
              end

              reqPartPrice = reqPartPrice * discountMultiplier
            end
          end
        end

        allParts[reqPart.slotPath] = {
          partName = reqPart.partName,
          slotPath = reqPart.slotPath,
          partNiceName = reqPart.partNiceName or reqPart.partName,
          slotNiceName = reqPart.slotName or '',
          price = reqPartPrice
        }
      end
    end

    applyPartsBySlotPath(completeConfig.partsTree, allParts)
  end

  local modelKey = initialVehicle.model
  local pendingPreview = {
    config = completeConfig,
    partList = flattenPartsTree(completeConfig.partsTree or {}),
    partConditions = deepcopy(initialVehicle.partConditions or {}),
    model = modelKey
  }

  replaceVehicleWithFuelHandling(vehObj, modelKey, completeConfig, nil, function()
    local liveVeh = getBusinessVehicleObject(businessId, vehicleId) or vehObj
    local liveId = liveVeh and liveVeh:getID() or nil
    local actualVehicleData = liveId and extensions.core_vehicle_manager.getVehicleData(liveId) or nil
    local loadedOk = actualVehicleData and actualVehicleData.config and actualVehicleData.config.partsTree and
      actualVehicleData.config.partsTree.chosenPartName and actualVehicleData.config.partsTree.chosenPartName ~= ""

    if not loadedOk then
      finishRestoreAfterFailedReplace(
        "That part change would make the vehicle unloadable. Change was not applied.")
      return
    end

    session.preview = pendingPreview
    finishPartReplaceConditionHandling(businessId, vehicleId, liveVeh or vehObj, completeConfig, function()
      session.operationInProgress = false
      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end
      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end
      requestVehiclePowerWeight(liveVeh or vehObj, businessId, vehicleId)
      finish(true)
    end)
  end)

  return true
end

local function installPartOnVehicle(businessId, vehicleId, partName, slotPath)
  return true
end

local function onPowerWeightReceived(requestId, power, weight, torqueData)
  local businessId, vehicleId = requestId:match("^(.+)_(.+)_")
  if businessId and vehicleId and power and weight and weight > 0 then
    local numericVehicleId = tonumber(vehicleId)
    local result = {
      power = power,
      weight = weight,
      powerToWeight = power / weight,
      torque = torqueData
    }
    if sessionMatches(businessId, numericVehicleId) then
      currentSession.powerWeight = result
    end

    guihooks.trigger('businessComputer:onVehiclePowerWeight', {
      success = true,
      businessId = businessId,
      vehicleId = numericVehicleId or vehicleId,
      power = power,
      weight = weight,
      powerToWeight = result.powerToWeight,
      torque = torqueData
    })
    if career_modules_business_racingTeam and career_modules_business_racingTeam.notifyTeamVehicleDynoPeakHp then
      career_modules_business_racingTeam.notifyTeamVehicleDynoPeakHp(businessId, numericVehicleId or vehicleId, power, weight)
    end
  end
end

local function getVehiclePowerWeight(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  if career_modules_business_businessSkillTree then
    local businessType
    if career_modules_business_businessManager and career_modules_business_businessManager.getAllBusinessObjects then
      local normalizedBusinessId = tostring(businessId)
      for currentBusinessType, _ in pairs(career_modules_business_businessManager.getAllBusinessObjects() or {}) do
        if career_modules_business_businessManager.getPurchasedBusinesses then
          local purchased = career_modules_business_businessManager.getPurchasedBusinesses(currentBusinessType) or {}
          if purchased[businessId] or purchased[normalizedBusinessId] then
            businessType = currentBusinessType
            break
          end
        end
      end
    end

    local dynoLevel = 0
    if businessType == "tuningShop" then
      dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "dyno") or 0
    elseif businessType == "racingTeam" then
      dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "qol", "dyno") or 0
    end
    if dynoLevel == 0 and businessType ~= "racingTeam" then
      return nil
    end
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return nil
  end

  local session = getActiveSession(businessId)
  if session and tostring(session.vehicleId) == tostring(vehicleId) and session.powerWeight then
    return session.powerWeight
  end

  requestVehiclePowerWeight(vehObj, businessId, vehicleId)

  return nil
end

local function getPreviewVehicleConfig(businessId)
  local session = getActiveSession(businessId)
  if session and session.preview then
    return session.preview.config
  end
  return nil
end

local function updatePreviewVehicleConfig(businessId, newConfig)
  local session = getActiveSession(businessId)
  if session and session.preview then
    session.preview.config = newConfig
    return true
  end
  return false
end

local function getInitialVehicleState(businessId)
  local session = getActiveSession(businessId)
  if session and session.initial then
    return deepcopy(session.initial)
  end
  return nil
end

local function commitSessionInitialFromPreview(businessId, vehicleId)
  local session = getActiveSession(businessId)
  if not session or not session.preview or not session.preview.config then
    return false
  end
  if vehicleId and tostring(session.vehicleId) ~= tostring(vehicleId) then
    return false
  end

  local previewConfig = deepcopy(session.preview.config)
  session.initial.config = previewConfig
  session.initial.partList = flattenPartsTree(previewConfig.partsTree or {})
  session.preview.config = deepcopy(previewConfig)
  session.preview.partList = flattenPartsTree(previewConfig.partsTree or {})
  return true
end

local function findChangedParts(baselineTree, newTree, changedParts, path)
  changedParts = changedParts or {}
  path = path or (baselineTree and baselineTree.path) or (newTree and newTree.path) or "/"

  local baselinePart = baselineTree and baselineTree.chosenPartName or ""
  local newPart = newTree and newTree.chosenPartName or ""

  if baselinePart ~= newPart then
    if newPart and newPart ~= "" then
      changedParts[path] = {
        partName = newPart,
        slotPath = path
      }
    end
  end

  local baselineChildren = baselineTree and baselineTree.children or {}
  local newChildren = newTree and newTree.children or {}

  for slotName, newChild in pairs(newChildren) do
    local childPath = newChild.path or (path .. slotName .. "/")
    local baselineChild = baselineChildren[slotName]
    findChangedParts(baselineChild, newChild, changedParts, childPath)
  end

  for slotName, baselineChild in pairs(baselineChildren) do
    if not newChildren[slotName] then
    end
  end

  return changedParts
end

local function addPartToCart(businessId, vehicleId, currentCart, partToAdd)
  if not businessId or not vehicleId or not partToAdd or not partToAdd.partName or not partToAdd.slotPath then
    return currentCart or {}
  end

  local session = ensureActiveSession(businessId, vehicleId)
  if not session or not session.initial or not session.initial.config then
    return currentCart or {}
  end

  local baselineCfg = getActiveSessionConfig(session)
  if not baselineCfg or not baselineCfg.partsTree then
    return currentCart or {}
  end
  local baselineTree = baselineCfg.partsTree

  local cart = deepcopy(currentCart or {})
  local slotData = session.slotData or {}

  for i = #cart, 1, -1 do
    local item = cart[i]
    if item.type == 'part' then
      if item.slotPath == partToAdd.slotPath or
        item.slotPath:match("^" .. partToAdd.slotPath:gsub("%-", "%%-") .. "[^/]+") then
        table.remove(cart, i)
      end
    end
  end

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return currentCart or {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return currentCart or {}
  end

  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)
  local vehicleModel = vehObj:getJBeamFilename()

  local tempCart = deepcopy(cart)
  local newPartItem = {
    type = 'part',
    partName = partToAdd.partName,
    partNiceName = partToAdd.partNiceName or partToAdd.partName,
    slotPath = partToAdd.slotPath,
    slotNiceName = partToAdd.slotNiceName or "",
    price = partToAdd.price or 0
  }

  if partToAdd.fromInventory then
    newPartItem.fromInventory = true
    newPartItem.partId = partToAdd.partId
    newPartItem.price = 0
  end

  table.insert(tempCart, newPartItem)

  local rollbackCfg = getActiveSessionConfig(session) or session.initial.config
  local initialConfig = deepcopy(rollbackCfg)

  local completeConfig = deepcopy(rollbackCfg)

  local partsBySlotPath = {}
  for _, part in ipairs(tempCart) do
    if part.type == 'part' and part.partName and part.slotPath then
      partsBySlotPath[part.slotPath] = {
        partName = part.partName,
        slotPath = part.slotPath
      }
    end
  end
  applyPartsBySlotPath(completeConfig.partsTree, partsBySlotPath)

  storeFuelLevels(vehObj, function(storedFuelLevels)
    local additionalVehicleData = {
      spawnWithEngineRunning = false
    }
    core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehId)

    local spawnOptions = {}
    spawnOptions.config = completeConfig
    spawnOptions.keepOtherVehRotation = true

    core_vehicles.replaceVehicle(vehicleModel, spawnOptions, vehObj)

    core_vehicleBridge.requestValue(vehObj, function()
      local actualVehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
      if not actualVehicleData or not actualVehicleData.config or not actualVehicleData.config.partsTree then
        core_vehicles.replaceVehicle(vehicleModel, {
          config = initialConfig,
          keepOtherVehRotation = true
        }, vehObj)
        restoreFuelLevels(vehObj, storedFuelLevels)
        return
      end

      local actualTree = actualVehicleData.config.partsTree

      local changedPartsMap = findChangedParts(baselineTree, actualTree, {})

      local finalCart = {}

      for _, item in ipairs(cart) do
        if item.type == 'part' then
          local isBeingChanged = false
          for slotPath, _ in pairs(changedPartsMap) do
            if item.slotPath == slotPath then
              isBeingChanged = true
              break
            end
          end
          if not isBeingChanged then
            table.insert(finalCart, item)
          end
        else
          table.insert(finalCart, item)
        end
      end

      for slotPath, partInfo in pairs(changedPartsMap) do
        local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partInfo.partName)

        local partNiceName = partInfo.partName
        if jbeamData and jbeamData.information and jbeamData.information.description then
          local desc = jbeamData.information.description
          partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
        else
          local partDescription = availableParts[partInfo.partName]
          if partDescription then
            if type(partDescription) == "string" then
              partNiceName = partDescription
            elseif partDescription.description then
              local desc = partDescription.description
              partNiceName = type(desc) == "table" and desc.description or desc or partInfo.partName
            end
          end
        end

        local partValue = 0
        if jbeamData then
          local baseValue = jbeamData.information and jbeamData.information.value or 100

          if career_modules_valueCalculator then
            local partForValueCalc = {
              name = partInfo.partName,
              value = baseValue,
              partCondition = {
                integrityValue = 1,
                odometer = 0,
                visualValue = 1
              },
              vehicleModel = vehicleModel
            }
            partValue = math.max(roundNear(career_modules_valueCalculator.getPartValue(partForValueCalc), 5) - 0.01, 0)
          else
            partValue = baseValue
          end

          local discountMultiplier = getPartSupplierDiscountMultiplier(businessId)
          partValue = partValue * discountMultiplier
        end

        local slotNiceName = ""
        local slotInfo = nil
        local slotName = slotPath:match("/([^/]+)/$") or ""

        local parentPath = slotPath:match("(.+)/[^/]+/$") or "/"
        local actualParentNode = getNodeFromSlotPath(actualTree, parentPath)
        if actualParentNode and actualParentNode.chosenPartName then
          local parentJbeamData = jbeamIO.getPart(vehicleData.ioCtx, actualParentNode.chosenPartName)
          if parentJbeamData and parentJbeamData.slotInfoUi and parentJbeamData.slotInfoUi[slotName] then
            slotInfo = parentJbeamData.slotInfoUi[slotName]
            local desc = slotInfo.description
            slotNiceName = type(desc) == "table" and desc.description or desc or slotName
          end
        end

        if slotNiceName == "" and slotData then
          if slotData[slotPath] then
            slotInfo = slotData[slotPath]
            if slotInfo.description then
              local desc = slotInfo.description
              slotNiceName = type(desc) == "table" and desc.description or desc or slotName
            end
          end

          if slotNiceName == "" then
            for path, info in pairs(slotData) do
              local pathSlotName = path:match("/([^/]+)/$") or ""
              if pathSlotName == slotName then
                slotInfo = info
                if info.description then
                  local desc = info.description
                  slotNiceName = type(desc) == "table" and desc.description or desc or slotName
                  break
                end
              end
            end
          end
        end

        if slotNiceName == "" then
          slotNiceName = slotName
        end

        local canRemove = slotAllowsRemoval(session, slotPath, vehicleData)

        local fromInventory = false
        local partId = nil
        if newPartItem.slotPath == slotPath and newPartItem.fromInventory then
          fromInventory = true
          partId = newPartItem.partId
          partValue = 0
        end

        local partData = {
          type = 'part',
          partName = partInfo.partName,
          partNiceName = partNiceName,
          slotPath = slotPath,
          slotNiceName = slotNiceName,
          price = partValue,
          canRemove = canRemove
        }
        
        if fromInventory then
          partData.fromInventory = true
          partData.partId = partId
        end

        if slotPath == partToAdd.slotPath then
          partData.partNiceName = partToAdd.partNiceName or partData.partNiceName
          partData.slotNiceName = partToAdd.slotNiceName or partData.slotNiceName

          if partToAdd.fromInventory then
            partData.fromInventory = true
            partData.partId = partToAdd.partId
            partData.price = 0
          else
            partData.price = partValue
          end
        end

        table.insert(finalCart, partData)
      end

      session.preview = {
        config = deepcopy(actualVehicleData.config),
        partList = flattenPartsTree(actualVehicleData.config.partsTree or {}),
        partConditions = deepcopy(session.initial.partConditions or {}),
        model = vehicleModel
      }

      restoreFuelLevels(vehObj, storedFuelLevels)

      guihooks.trigger('businessComputer:onPartCartUpdated', {
        businessId = businessId,
        vehicleId = vehicleId,
        cart = finalCart
      })

      if career_modules_business_businessComputer then
        career_modules_business_businessComputer.requestVehiclePartsTree(businessId, vehicleId)
      end

      if career_modules_business_businessVehicleTuning then
        career_modules_business_businessVehicleTuning.clearTuningDataCache()
      end

      requestVehiclePowerWeight(vehObj, businessId, vehicleId)
    end, 'ping')
  end)

  return cart
end

local function findRemovedParts(businessId, vehicleId)
  if not businessId or not vehicleId then
    return {}
  end

  local session = getActiveSession(businessId)
  if not session or not session.initial or not session.preview then
    return {}
  end

  local initialVehicle = session.initial
  local previewVehicle = session.preview

  if not initialVehicle or not previewVehicle then
    return {}
  end

  local baselinePartList = initialVehicle.partList or {}
  local finalPartList = previewVehicle.partList or {}

  local removedParts = {}

  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return {}
  end

  local vehId = vehObj:getID()
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData then
    return {}
  end

  local vehicle = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not vehicle or not vehicle.vehicleConfig then
    return {}
  end
  local vehicleModel = vehicle.vehicleConfig.model_key or vehicle.model_key

  for slotPath, partName in pairs(baselinePartList) do
    if partName and partName ~= "" then
      local finalPartName = finalPartList[slotPath]
      if not finalPartName or finalPartName == "" or finalPartName ~= partName then
        local partCondition = initialVehicle.partConditions and initialVehicle.partConditions[slotPath .. partName]
        if not partCondition then
          partCondition = {
            integrityValue = 1,
            visualValue = 1,
            odometer = 0
          }
        end

        local partData = {
          name = partName,
          containingSlot = slotPath,
          slot = slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$") or "",
          vehicleModel = vehicleModel,
          year = vehicle.year,
          partCondition = partCondition,
          partPath = slotPath .. partName,
          rlsTireState = vehicle.rlsTireStateByPartPath and
                           deepcopy(vehicle.rlsTireStateByPartPath[slotPath .. partName]) or nil,
        }

        if career_modules_valueCalculator then
          partData.value = career_modules_valueCalculator.getPartValue(partData, true) or 0
        else
          local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, partName)
          partData.value = (jbeamData and jbeamData.information and jbeamData.information.value) or 100
        end

        table.insert(removedParts, partData)
      end
    end
  end

  return removedParts
end

local function clearPreviewVehicle(businessId)
  if businessId and sessionMatches(businessId) then
    resetCurrentSession()
  end
end

local function tryEmergencyRestoreSessionVehicle(businessId, vehicleId)
  if not currentSession or not sessionMatches(businessId, vehicleId) then
    return
  end
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if vehObj then
    return
  end
  local initial = currentSession.initial
  if not initial or not initial.config then
    return
  end
  currentSession.operationInProgress = false
  local restoreConfig, restorePartConditions = resolveRestoreBaseline(businessId, vehicleId, currentSession)
  emergencyRestoreBusinessVehicle(businessId, vehicleId, restoreConfig, restorePartConditions)
end

local rollbackOnUiCloseInProgress = false
local function onUIPlayStateChanged(enteredPlay)
  if not enteredPlay then
    return
  end
  if rollbackOnUiCloseInProgress or not currentSession then
    return
  end
  if currentSession.operationInProgress then
    tryEmergencyRestoreSessionVehicle(currentSession.businessId, currentSession.vehicleId)
  end
  if currentSession.operationInProgress then
    return
  end

  rollbackOnUiCloseInProgress = true
  local bId = currentSession.businessId
  local vId = currentSession.vehicleId
  resetVehicleToOriginal(bId, vId)
  clearPreviewVehicle(bId)
  rollbackOnUiCloseInProgress = false
end

local function onUiChangedState(toState, fromState)
  if rollbackOnUiCloseInProgress or not currentSession then
    return
  end
  if currentSession.operationInProgress then
    tryEmergencyRestoreSessionVehicle(currentSession.businessId, currentSession.vehicleId)
  end
  if currentSession.operationInProgress then
    return
  end

  if fromState == 'business-computer' and toState ~= 'business-computer' then
    rollbackOnUiCloseInProgress = true
    local bId = currentSession.businessId
    local vId = currentSession.vehicleId
    resetVehicleToOriginal(bId, vId)
    clearPreviewVehicle(bId)
    rollbackOnUiCloseInProgress = false
  end
end

local function onUIInitialised()
  if rollbackOnUiCloseInProgress or not currentSession then
    return
  end
  if currentSession.operationInProgress then
    tryEmergencyRestoreSessionVehicle(currentSession.businessId, currentSession.vehicleId)
  end
  if currentSession.operationInProgress then
    return
  end

  rollbackOnUiCloseInProgress = true
  local bId = currentSession.businessId
  local vId = currentSession.vehicleId
  resetVehicleToOriginal(bId, vId)
  clearPreviewVehicle(bId)
  rollbackOnUiCloseInProgress = false
end

local function requestVehiclePowerWeightAfterPurchase(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return false
  end
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end
  requestVehiclePowerWeight(vehObj, businessId, vehicleId, true)
  return true
end

local function invalidateAndRequestVehiclePowerWeight(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return false
  end
  if sessionMatches(businessId, vehicleId) and currentSession then
    currentSession.powerWeight = nil
  end
  local vehObj = getBusinessVehicleObject(businessId, vehicleId)
  if not vehObj then
    return false
  end
  requestVehiclePowerWeight(vehObj, businessId, vehicleId)
  return true
end

M.onPowerWeightReceived = onPowerWeightReceived
M.requestVehiclePowerWeightAfterPurchase = requestVehiclePowerWeightAfterPurchase
M.invalidateAndRequestVehiclePowerWeight = invalidateAndRequestVehiclePowerWeight
M.initializePreviewVehicle = initializePreviewVehicle
M.resetVehicleToOriginal = resetVehicleToOriginal
M.applyPartsToVehicle = applyPartsToVehicle
M.applyCartPartsToVehicle = applyCartPartsToVehicle
M.installPartOnVehicle = installPartOnVehicle
M.getVehiclePowerWeight = getVehiclePowerWeight
M.getPreviewVehicleConfig = getPreviewVehicleConfig
M.updatePreviewVehicleConfig = updatePreviewVehicleConfig
M.getInitialVehicleState = getInitialVehicleState
M.commitSessionInitialFromPreview = commitSessionInitialFromPreview
M.clearPreviewVehicle = clearPreviewVehicle
M.getAllRequiredParts = getAllRequiredParts
M.addPartToCart = addPartToCart
M.findRemovedParts = findRemovedParts
M.onUIPlayStateChanged = onUIPlayStateChanged
M.onUiChangedState = onUiChangedState
M.onUIInitialised = onUIInitialised

return M
