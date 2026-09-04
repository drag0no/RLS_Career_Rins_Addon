local M = {}

M.dependencies = {
  "career_career",
  "career_modules_bank",
  "career_modules_business_businessInventory",
  "career_modules_business_businessManager",
  "career_modules_business_businessPartInventory",
  "career_modules_dynamicWeather",
  "career_modules_inventory",
  "career_modules_maintenanceMode",
  "career_modules_partInventory",
  "career_modules_payment",
  "career_saveSystem",
}

local jbeamIO = require("jbeam/io")
local tireModel = require("rls_tire_model")

local metersToMiles = 1 / 1609.344
local contextTimer = 0
local burnoutOverrides = {}
local lastContextSignatures = {}
local providerNoticeKey
local ioCtxCache = {}
local partRevisions = {}
local runtimeOwnersByVehId = {}
local groundModelsCache
local groundModelsCacheSource

local function deepCopy(value)
  if type(deepcopy) == "function" then
    return deepcopy(value)
  end
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = deepCopy(nested)
  end
  return result
end

local function round(value, digits)
  local scale = 10 ^ (digits or 0)
  return math.floor((tonumber(value) or 0) * scale + 0.5) / scale
end

local function isMaintenanceEnabled()
  return career_modules_maintenanceMode and career_modules_maintenanceMode.isEnabled and
           career_modules_maintenanceMode.isEnabled() == true
end

local function markDirty(inventoryId)
  if career_modules_inventory and career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(tonumber(inventoryId))
  end
end

local function vehicleDataForInventory(inventoryId)
  return career_modules_inventory and career_modules_inventory.getVehicle and
           career_modules_inventory.getVehicle(tonumber(inventoryId)) or nil
end

local function businessVehicleData(businessId, vehicleId)
  local inventory = career_modules_business_businessInventory
  return inventory and inventory.getVehicleById and inventory.getVehicleById(businessId, vehicleId) or nil
end

local function markOwnerDirty(owner)
  if owner and owner.kind == "personal" then
    markDirty(owner.inventoryId)
  end
end

local function freshWheelState()
  return {remaining = 1, flat = false}
end

local function partState(part)
  if type(part) ~= "table" then
    return nil
  end
  if type(part.rlsTireState) == "table" then
    return part.rlsTireState
  end
  if type(part.tags) == "table" and type(part.tags.rlsTireState) == "table" then
    return part.tags.rlsTireState
  end
  return nil
end

local function setPartState(part, state)
  if type(part) ~= "table" then
    return
  end
  part.tags = type(part.tags) == "table" and part.tags or {}
  part.rlsTireState = state
  -- The base inventory reconciler preserves tags. Keep a mirror here so tire
  -- state survives a spawned-vehicle reconciliation that rebuilds the record.
  part.tags.rlsTireState = state
end

local function milesForPart(part, vehicleData)
  local odometer = part and part.partCondition and tonumber(part.partCondition.odometer)
  if odometer ~= nil then
    return math.max(0, odometer * metersToMiles)
  end
  return math.max(0, tonumber(vehicleData and vehicleData.mileage) or 0) * metersToMiles
end

local function ensurePartWheelState(part, wheelName, vehicleData, forcedFresh)
  local state = partState(part)
  local created = false
  if type(state) ~= "table" then
    state = {schemaVersion = 1, wheels = {}}
  end
  state.schemaVersion = 1
  state.wheels = type(state.wheels) == "table" and state.wheels or {}
  local wheelState = state.wheels[wheelName]
  if type(wheelState) ~= "table" then
    created = true
    wheelState = {
      remaining = forcedFresh and 1 or tireModel.remainingFromMiles(milesForPart(part, vehicleData)),
      flat = false,
    }
    state.wheels[wheelName] = wheelState
  end
  wheelState.remaining = tireModel.clamp(wheelState.remaining, 0, 1)
  wheelState.flat = wheelState.flat == true
  setPartState(part, state)
  return wheelState, state, created
end

local function personalInventory()
  return career_modules_partInventory and career_modules_partInventory.getInventory and
           career_modules_partInventory.getInventory() or {}
end

local function findPersonalPart(inventoryId, partPath, partOrigin, containingSlot)
  inventoryId = tonumber(inventoryId)
  local fallbackId, fallbackPart
  for partId, part in pairs(personalInventory()) do
    if part and tonumber(part.location) == inventoryId then
      if partPath and part.partPath == partPath then
        return partId, part
      end
      if containingSlot and part.containingSlot == containingSlot and (not partOrigin or part.name == partOrigin) then
        return partId, part
      end
      if partOrigin and part.name == partOrigin and not fallbackPart then
        fallbackId, fallbackPart = partId, part
      end
    end
  end
  return fallbackId, fallbackPart
end

local function ensureVehicleFallbackState(vehicleData, path, wheelName, remaining)
  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  local state = vehicleData.rlsTireStateByPartPath[path]
  local created = false
  if type(state) ~= "table" then
    created = true
    state = {schemaVersion = 1, wheels = {}}
    vehicleData.rlsTireStateByPartPath[path] = state
  end
  state.wheels = type(state.wheels) == "table" and state.wheels or {}
  if type(state.wheels[wheelName]) ~= "table" then
    created = true
    state.wheels[wheelName] = {remaining = tireModel.clamp(remaining, 0, 1), flat = false}
  end
  return state.wheels[wheelName], state, created
end

local function currentTireSignature(vehicleData)
  local rows = {}
  for _, wheel in ipairs(vehicleData and vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    table.insert(rows, string.format("%s:%d:%d", tostring(wheel.name),
      math.floor(tireModel.clamp(wheel.remaining, 0, 1) * 100 + 0.5), wheel.flat == true and 1 or 0))
  end
  table.sort(rows)
  return table.concat(rows, "|")
end

local function maybeInvalidateInspection(vehicleData)
  local computerState = vehicleData and vehicleData.maintenanceComputerState
  local inspection = computerState and computerState.tireInspection
  if inspection and inspection.signature ~= currentTireSignature(vehicleData) then
    computerState.tireInspection = nil
    return true
  end
  return false
end

local function showProviderNotice(provider)
  if type(provider) ~= "table" or provider.source ~= "external" then
    return
  end
  local key = table.concat({tostring(provider.id), tostring(provider.version), tostring(provider.apiVersion)}, ":")
  if providerNoticeKey == key then
    return
  end
  providerNoticeKey = key
  local message
  if provider.integrated == true then
    message = string.format("External tire provider selected: %s %s", provider.name or provider.id or "Tyre Wear and Thermals",
      provider.version or "")
  else
    message = "External Tyre Wear and Thermals selected (legacy API). RLS persistence, maintenance gating, towing protection, and tire replacement are unavailable."
  end
  if ui_message then
    ui_message(message, 12, "tireProvider", provider.integrated and "info" or "warning")
  end
end

function M.receiveVehicleState(vehId, payload)
  if type(payload) ~= "table" then
    return false
  end
  vehId = tonumber(vehId)
  local owner = runtimeOwnersByVehId[vehId]
  if not owner then
    local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and
                          career_modules_inventory.getInventoryIdFromVehicleId(vehId) or nil
    if inventoryId then owner = {kind = "personal", inventoryId = tonumber(inventoryId)} end
  end
  local inventoryId = owner and owner.inventoryId or nil
  local vehicleData = owner and owner.kind == "business" and
                        businessVehicleData(owner.businessId, owner.vehicleId) or
                        (inventoryId and vehicleDataForInventory(inventoryId) or nil)
  if not vehicleData then
    return false
  end

  local providerChanged = false
  if type(payload.provider) == "table" then
    local previousProvider = type(serialize) == "function" and serialize(vehicleData.rlsTireProvider) or nil
    local nextProvider = type(serialize) == "function" and serialize(payload.provider) or nil
    providerChanged = previousProvider ~= nextProvider
    vehicleData.rlsTireProvider = deepCopy(payload.provider)
    showProviderNotice(payload.provider)
  end

  local persistenceEnabled = isMaintenanceEnabled() or
    (owner.kind == "personal" and burnoutOverrides[tonumber(inventoryId)] == true)
  if not persistenceEnabled then
    if providerChanged then markOwnerDirty(owner) end
    return true
  end

  local previousSignature = currentTireSignature(vehicleData)
  local layout = {schemaVersion = 1, wheels = {}}
  local stateCorrectionNeeded = false
  for _, reported in ipairs(payload.wheels or {}) do
    if type(reported) == "table" and reported.name then
      local partId, part
      if owner.kind == "personal" then
        partId, part = findPersonalPart(inventoryId, reported.partPath, reported.partOrigin, reported.containingSlot)
      end
      local storedWheel
      if part then
        local created
        storedWheel, _, created = ensurePartWheelState(part, reported.name, vehicleData)
        if not created then
          storedWheel.remaining = tireModel.clamp(reported.remaining, 0, 1)
          storedWheel.flat = reported.flat == true
        else
          stateCorrectionNeeded = true
        end
      else
        local path = reported.partPath or reported.partOrigin or ("wheel:" .. tostring(reported.name))
        local conditionOdometer = vehicleData.partConditions and vehicleData.partConditions[path] and
                                    tonumber(vehicleData.partConditions[path].odometer) or nil
        local fallbackMiles = conditionOdometer ~= nil and conditionOdometer * metersToMiles or
                                (tonumber(vehicleData.mileage) or 0) * metersToMiles
        local created
        storedWheel, _, created = ensureVehicleFallbackState(vehicleData, path, reported.name,
          tireModel.remainingFromMiles(fallbackMiles))
        if not created then
          storedWheel.remaining = tireModel.clamp(reported.remaining, 0, 1)
          storedWheel.flat = reported.flat == true
        else
          stateCorrectionNeeded = true
        end
      end

      table.insert(layout.wheels, {
        name = tostring(reported.name),
        partId = partId,
        partPath = reported.partPath or (part and part.partPath),
        partOrigin = reported.partOrigin or (part and part.name),
        containingSlot = (part and part.containingSlot) or reported.containingSlot,
        width = tonumber(reported.width),
        remaining = storedWheel.remaining,
        flat = storedWheel.flat,
      })
    end
  end
  if #layout.wheels > 0 then
    table.sort(layout.wheels, function(a, b) return a.name < b.name end)
    vehicleData.rlsTireLayout = layout
  end

  local changed = previousSignature ~= currentTireSignature(vehicleData)
  changed = maybeInvalidateInspection(vehicleData) or changed
  if changed or providerChanged then markOwnerDirty(owner) end
  if stateCorrectionNeeded then
    local revisionKey = owner.kind == "business" and
                          ("b:" .. tostring(owner.businessId) .. ":" .. tostring(owner.vehicleId)) or
                          tonumber(inventoryId)
    partRevisions[revisionKey] = (tonumber(partRevisions[revisionKey]) or 0) + 1
    if owner.kind == "business" then
      M.sendContextForBusinessVehicle(owner.businessId, owner.vehicleId, true)
    else
      M.sendContextForVehicle(vehId, true)
    end
  end
  return true
end

local function getAmbientTemperature()
  if core_environment and core_environment.getTemperatureK then
    return (tonumber(core_environment.getTemperatureK()) or 294.15) - 273.15
  end
  return 21
end

local function getGroundModels()
  local source = core_environment and core_environment.groundModels or nil
  if groundModelsCache and groundModelsCacheSource == source then
    return groundModelsCache
  end
  local result = {}
  for name, model in pairs(source or {}) do
    local cdata = model and model.cdata or {}
    result[tostring(name)] = {
      staticFrictionCoefficient = tonumber(cdata.staticFrictionCoefficient) or 1,
      slidingFrictionCoefficient = tonumber(cdata.slidingFrictionCoefficient) or 1,
    }
  end
  groundModelsCache = result
  groundModelsCacheSource = source
  return groundModelsCache
end

local function getTireWeatherState()
  local result = {
    roadWetness = 0,
    wetGripMultipliers = {standard = 1.00, sport = 0.94, race = 0.80, drag = 0.72},
    wetGroundModels = {},
  }
  local weather = career_modules_dynamicWeather
  if not weather or type(weather.getTireWeatherState) ~= "function" then return result end

  local ok, reported = pcall(weather.getTireWeatherState)
  if not ok or type(reported) ~= "table" then return result end
  result.roadWetness = round(tireModel.clamp(reported.roadWetness, 0, 1), 2)
  if type(reported.wetGripMultipliers) == "table" then
    for compound, fallback in pairs(result.wetGripMultipliers) do
      result.wetGripMultipliers[compound] = tireModel.clamp(
        tonumber(reported.wetGripMultipliers[compound]) or fallback, 0.10, 1)
    end
  end
  if type(reported.wetGroundModels) == "table" then
    for name, affected in pairs(reported.wetGroundModels) do
      if affected == true then result.wetGroundModels[tostring(name)] = true end
    end
  end
  return result
end

local function addTireWeatherContext(context)
  local weather = getTireWeatherState()
  context.roadWetness = weather.roadWetness
  context.wetGripMultipliers = weather.wetGripMultipliers
  context.wetGroundModels = weather.wetGroundModels
  return context
end

local function vehicleTypeIsTrailer(vehicleData)
  local modelKey = vehicleData and (vehicleData.model or vehicleData.model_key or
                     (vehicleData.vehicleConfig and vehicleData.vehicleConfig.model_key)) or nil
  local modelData = modelKey and core_vehicles and core_vehicles.getModel and core_vehicles.getModel(modelKey) or nil
  local model = modelData and (modelData.model or modelData) or {}
  local function containsTrailer(value)
    if type(value) == "table" then
      for key, nested in pairs(value) do
        if containsTrailer(key) or containsTrailer(nested) then return true end
      end
      return false
    end
    return string.find(string.lower(tostring(value or "")), "trailer", 1, true) ~= nil
  end
  return containsTrailer(vehicleData and (vehicleData.Type or vehicleData.type)) or containsTrailer(model.Type)
end

local function isTowedChild(vehId)
  for _, connection in pairs(core_trailerRespawn and core_trailerRespawn.getTrailerData and
                               core_trailerRespawn.getTrailerData() or {}) do
    if type(connection) == "table" and tonumber(connection.trailerId) == tonumber(vehId) then
      return true
    end
  end
  return false
end

local function buildInitialWheelState(inventoryId, vehicleData)
  local result = {}
  if inventoryId ~= nil then
    for _, part in pairs(personalInventory()) do
      if part and tonumber(part.location) == tonumber(inventoryId) then
        local state = partState(part)
        for wheelName, wheelState in pairs(state and state.wheels or {}) do
          result[wheelName] = deepCopy(wheelState)
        end
      end
    end
  end
  for _, state in pairs(vehicleData.rlsTireStateByPartPath or {}) do
    for wheelName, wheelState in pairs(state and state.wheels or {}) do
      if not result[wheelName] then
        result[wheelName] = deepCopy(wheelState)
      end
    end
  end
  return result
end

function M.sendContextForVehicle(vehId, force)
  if not career_modules_inventory then return false end
  vehId = tonumber(vehId)
  local vehObj = vehId and getObjectByID(vehId) or nil
  local inventoryId = vehObj and career_modules_inventory.getInventoryIdFromVehicleId and
                        career_modules_inventory.getInventoryIdFromVehicleId(vehId) or nil
  local vehicleData = inventoryId and vehicleDataForInventory(inventoryId) or nil
  if not vehObj or not vehicleData then
    return false
  end
  runtimeOwnersByVehId[vehId] = {kind = "personal", inventoryId = tonumber(inventoryId)}

  local excludedReason
  if vehicleTypeIsTrailer(vehicleData) then
    excludedReason = "trailer"
  elseif isTowedChild(vehId) then
    excludedReason = "towed"
  end
  local burnout = burnoutOverrides[tonumber(inventoryId)] == true
  local tireRuntimeEnabled = (isMaintenanceEnabled() or burnout) and excludedReason == nil
  local context = addTireWeatherContext({
    apiVersion = 1,
    inventoryId = tonumber(inventoryId),
    enabled = tireRuntimeEnabled,
    maintenanceEnabled = isMaintenanceEnabled(),
    burnoutOverride = burnout,
    excludedReason = excludedReason,
    ambientTemperature = getAmbientTemperature(),
    initialState = tireRuntimeEnabled and buildInitialWheelState(inventoryId, vehicleData) or {},
    defaultRemaining = tireRuntimeEnabled and
      tireModel.remainingFromMiles((tonumber(vehicleData.mileage) or 0) * metersToMiles) or 1,
    groundModels = getGroundModels(),
    stateRevision = tonumber(partRevisions[tonumber(inventoryId)]) or 0,
  })
  local signature = type(serialize) == "function" and serialize({context.enabled, context.burnoutOverride,
    context.excludedReason, context.ambientTemperature, context.initialState, context.roadWetness,
    context.wetGripMultipliers, context.wetGroundModels}) or tostring(os.time())
  if not force and lastContextSignatures[vehId] == signature then
    return true
  end
  lastContextSignatures[vehId] = signature
  vehObj:queueLuaCommand("rlsTireProvider.configure(" .. serialize(context) .. ")")
  return true
end

function M.sendContextForBusinessVehicle(businessId, vehicleId, force)
  local businessInventory = career_modules_business_businessInventory
  local vehId = businessInventory and businessInventory.getSpawnedVehicleId and
                  businessInventory.getSpawnedVehicleId(businessId, vehicleId) or nil
  local vehObj = vehId and getObjectByID(vehId) or nil
  local vehicleData = businessVehicleData(businessId, vehicleId)
  if not vehObj or not vehicleData then return false end

  vehId = tonumber(vehId)
  runtimeOwnersByVehId[vehId] = {
    kind = "business",
    businessId = businessId,
    vehicleId = tonumber(vehicleId) or vehicleId,
  }
  local excludedReason = vehicleTypeIsTrailer(vehicleData) and "trailer" or (isTowedChild(vehId) and "towed" or nil)
  local revisionKey = "b:" .. tostring(businessId) .. ":" .. tostring(vehicleId)
  local tireRuntimeEnabled = isMaintenanceEnabled() and excludedReason == nil
  local context = addTireWeatherContext({
    apiVersion = 1,
    ownerKind = "business",
    businessId = businessId,
    businessVehicleId = tonumber(vehicleId) or vehicleId,
    enabled = tireRuntimeEnabled,
    maintenanceEnabled = isMaintenanceEnabled(),
    burnoutOverride = false,
    excludedReason = excludedReason,
    ambientTemperature = getAmbientTemperature(),
    initialState = tireRuntimeEnabled and buildInitialWheelState(nil, vehicleData) or {},
    defaultRemaining = tireRuntimeEnabled and
      tireModel.remainingFromMiles((tonumber(vehicleData.mileage) or 0) * metersToMiles) or 1,
    groundModels = getGroundModels(),
    stateRevision = tonumber(partRevisions[revisionKey]) or 0,
  })
  local signature = type(serialize) == "function" and serialize({context.enabled, context.excludedReason,
    context.ambientTemperature, context.initialState, context.roadWetness,
    context.wetGripMultipliers, context.wetGroundModels}) or tostring(os.time())
  if not force and lastContextSignatures[vehId] == signature then return true end
  lastContextSignatures[vehId] = signature
  vehObj:queueLuaCommand("rlsTireProvider.configure(" .. serialize(context) .. ")")
  return true
end

local function applyFreshTiresOnVehId(vehId)
  vehId = tonumber(vehId)
  if not vehId then
    return
  end
  lastContextSignatures[vehId] = nil
  local vehObj = getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand(
      "if rlsTireProvider and rlsTireProvider.applyFreshAndInflate then rlsTireProvider.applyFreshAndInflate() end")
  end
end

function M.registerBusinessVehicle(businessId, vehicleId, vehId)
  if not vehId then return false end
  runtimeOwnersByVehId[tonumber(vehId)] = {
    kind = "business", businessId = businessId, vehicleId = tonumber(vehicleId) or vehicleId,
  }
  lastContextSignatures[tonumber(vehId)] = nil
  return M.sendContextForBusinessVehicle(businessId, vehicleId, true)
end

function M.sendContextForInspectionVehicle(vehId, force)
  vehId = tonumber(vehId)
  local owner = vehId and runtimeOwnersByVehId[vehId] or nil
  local vehObj = vehId and getObjectByID(vehId) or nil
  if not vehObj or not owner or owner.kind ~= "inspection" then return false end

  local excludedReason = vehicleTypeIsTrailer(owner.vehicleInfo) and "trailer" or nil
  local tireRuntimeEnabled = isMaintenanceEnabled() and excludedReason == nil
  local previewMileageMeters = tonumber(owner.vehicleInfo and
    (owner.vehicleInfo.wearMileage or owner.vehicleInfo.Mileage)) or 0
  local context = addTireWeatherContext({
    apiVersion = 1,
    ownerKind = "inspection",
    shopId = owner.shopId,
    readOnly = true,
    enabled = tireRuntimeEnabled,
    maintenanceEnabled = isMaintenanceEnabled(),
    burnoutOverride = false,
    excludedReason = excludedReason,
    ambientTemperature = getAmbientTemperature(),
    initialState = {},
    defaultRemaining = tireRuntimeEnabled and
      tireModel.remainingFromMiles(previewMileageMeters * metersToMiles) or 1,
    groundModels = getGroundModels(),
    stateRevision = 0,
  })
  local signature = type(serialize) == "function" and serialize({context.enabled, context.excludedReason,
    context.ambientTemperature, context.defaultRemaining, context.shopId, context.roadWetness,
    context.wetGripMultipliers, context.wetGroundModels}) or tostring(os.time())
  if not force and lastContextSignatures[vehId] == signature then return true end
  lastContextSignatures[vehId] = signature
  vehObj:queueLuaCommand("rlsTireProvider.configure(" .. serialize(context) .. ")")
  return true
end

function M.registerInspectionVehicle(vehId, vehicleInfo)
  vehId = tonumber(vehId)
  if not vehId or type(vehicleInfo) ~= "table" then return false end
  runtimeOwnersByVehId[vehId] = {
    kind = "inspection",
    shopId = vehicleInfo.shopId,
    vehicleInfo = {
      shopId = vehicleInfo.shopId,
      model = vehicleInfo.model,
      model_key = vehicleInfo.model_key,
      Type = vehicleInfo.Type,
      type = vehicleInfo.type,
      Mileage = tonumber(vehicleInfo.Mileage) or 0,
      wearMileage = tonumber(vehicleInfo.wearMileage),
    },
  }
  lastContextSignatures[vehId] = nil
  return M.sendContextForInspectionVehicle(vehId, true)
end

function M.unregisterInspectionVehicle(vehId)
  vehId = tonumber(vehId)
  local owner = vehId and runtimeOwnersByVehId[vehId] or nil
  if not owner or owner.kind ~= "inspection" then return false end
  runtimeOwnersByVehId[vehId] = nil
  lastContextSignatures[vehId] = nil

  -- A successful sale may have assigned inventory ownership before inspection
  -- cleanup runs. Hand the live vehicle directly to its persistent context.
  if M.sendContextForVehicle(vehId, true) then return true end
  local vehObj = vehId and getObjectByID(vehId) or nil
  if vehObj then
    vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.configure({enabled=false," ..
      "maintenanceEnabled=false,ambientTemperature=21,initialState={},defaultRemaining=1,groundModels={}}) end")
  end
  return true
end

function M.unregisterBusinessVehicle(businessId, vehicleId, vehId)
  vehId = tonumber(vehId)
  local vehObj = vehId and getObjectByID(vehId) or nil
  if vehObj then
    vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState(); rlsTireProvider.resetThermalsAndGrip() end")
  end
  runtimeOwnersByVehId[vehId] = nil
  lastContextSignatures[vehId] = nil
  return true
end

local function sendAllContexts(force)
  for inventoryId in pairs(career_modules_inventory and career_modules_inventory.getVehicles and
                             career_modules_inventory.getVehicles() or {}) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId and
                    career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    if vehId then
      M.sendContextForVehicle(vehId, force)
    end
  end
  for vehId, owner in pairs(runtimeOwnersByVehId) do
    if owner.kind == "business" then
      if getObjectByID(vehId) then
        M.sendContextForBusinessVehicle(owner.businessId, owner.vehicleId, force)
      else
        runtimeOwnersByVehId[vehId] = nil
        lastContextSignatures[vehId] = nil
      end
    elseif owner.kind == "inspection" then
      if getObjectByID(vehId) then
        M.sendContextForInspectionVehicle(vehId, force)
      else
        runtimeOwnersByVehId[vehId] = nil
        lastContextSignatures[vehId] = nil
      end
    end
  end
end

function M.setBurnoutOverride(inventoryId, enabled)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  burnoutOverrides[inventoryId] = enabled == true or nil
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId and
                  career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  if vehId then
    M.sendContextForVehicle(vehId, true)
  end
  return true
end

local function catalogInfo(vehicleModel, partName, fallbackPart)
  local info = {
    name = fallbackPart and ((fallbackPart.description and fallbackPart.description.description) or fallbackPart.name) or partName,
    value = tonumber(fallbackPart and fallbackPart.value) or 100,
  }
  if not vehicleModel or not partName then
    return info
  end
  local ioCtx = ioCtxCache[vehicleModel]
  if ioCtx == nil then
    ioCtx = jbeamIO.startLoading({"/vehicles/" .. tostring(vehicleModel) .. "/", "/vehicles/common/"})
    ioCtxCache[vehicleModel] = ioCtx or false
  end
  if ioCtx then
    local partData = jbeamIO.getPart(ioCtx, partName)
    if partData and partData.information then
      info.value = tonumber(partData.information.value) or info.value
      info.name = partData.information.name or info.name
    end
  end
  if core_vehicle_partmgmt and core_vehicle_partmgmt.getTranslation then
    local ok, translated = pcall(core_vehicle_partmgmt.getTranslation, info.name, "ui.vehicleconfig.information.name.")
    if ok and translated then
      info.name = translated
    end
  end
  if type(info.name) ~= "string" then
    info.name = tostring(partName)
  end
  return info
end

local function groupLabel(index, wheels)
  local hasFront = false
  for _, wheel in ipairs(wheels) do
    if string.sub(string.upper(wheel.name or ""), 1, 1) == "F" then
      hasFront = true
      break
    end
  end
  if hasFront then
    return index == 1 and "Front Axle" or ("Front Axle " .. tostring(index))
  end
  return index == 1 and "Rear Axle" or ("Rear Axle " .. tostring(index))
end

local function buildAxleGroups(inventoryId, vehicleData, isBusiness)
  local grouped = {}
  for _, wheel in ipairs(vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    -- A pressure-wheel row may report the generic `main` containing slot even
    -- though its active tire part path is axle-specific. The fitted tire path
    -- is therefore the stable grouping key for replacement and pricing.
    local key = wheel.partPath or wheel.containingSlot or wheel.partOrigin or wheel.name
    grouped[key] = grouped[key] or {key = key, wheels = {}, parts = {}}
    table.insert(grouped[key].wheels, wheel)
    local partKey = wheel.partId and ("id:" .. tostring(wheel.partId)) or ("path:" .. tostring(wheel.partPath or key))
    grouped[key].parts[partKey] = grouped[key].parts[partKey] or {
      partId = wheel.partId,
      partPath = wheel.partPath,
      partOrigin = wheel.partOrigin,
      containingSlot = wheel.containingSlot,
    }
  end

  local front, rear = {}, {}
  for _, group in pairs(grouped) do
    table.sort(group.wheels, function(a, b) return a.name < b.name end)
    local isFront = string.sub(string.upper(group.wheels[1].name or ""), 1, 1) == "F"
    table.insert(isFront and front or rear, group)
  end
  table.sort(front, function(a, b) return a.key < b.key end)
  table.sort(rear, function(a, b) return a.key < b.key end)

  local result = {}
  local function appendGroups(groups, prefix)
    for index, group in ipairs(groups) do
      local subtotal = 0
      local partNames = {}
      local partsArray = {}
      for _, descriptor in pairs(group.parts) do
        local partId, part
        if not isBusiness then
          partId, part = findPersonalPart(inventoryId, descriptor.partPath, descriptor.partOrigin,
            descriptor.containingSlot)
        end
        descriptor.partId = descriptor.partId or partId
        local vehicleModel = vehicleData.model or vehicleData.model_key or
                               (vehicleData.vehicleConfig and vehicleData.vehicleConfig.model_key)
        local info = catalogInfo(vehicleModel, descriptor.partOrigin or (part and part.name), part)
        descriptor.name = info.name
        descriptor.price = info.value
        subtotal = subtotal + info.value
        partNames[info.name] = true
        table.insert(partsArray, descriptor)
      end
      table.sort(partsArray, function(a, b) return tostring(a.partPath) < tostring(b.partPath) end)
      local names = {}
      for name in pairs(partNames) do table.insert(names, name) end
      table.sort(names)
      local remainingTotal, flat = 0, false
      local wheelStates = {}
      for _, wheel in ipairs(group.wheels) do
        remainingTotal = remainingTotal + tireModel.clamp(wheel.remaining, 0, 1)
        flat = flat or wheel.flat == true
        table.insert(wheelStates, {
          name = wheel.name,
          remainingPercent = math.floor(tireModel.clamp(wheel.remaining, 0, 1) * 100 + 0.5),
          flat = wheel.flat == true,
        })
      end
      local id = prefix .. tostring(index)
      table.insert(result, {
        id = id,
        label = groupLabel(index, group.wheels),
        tireName = table.concat(names, ", "),
        tireCount = #group.wheels,
        remainingPercent = math.floor(remainingTotal / math.max(#group.wheels, 1) * 100 + 0.5),
        flat = flat,
        subtotal = round(subtotal, 2),
        perTirePrice = round(subtotal / math.max(#group.wheels, 1), 2),
        parts = partsArray,
        wheels = deepCopy(group.wheels),
        wheelStates = wheelStates,
      })
    end
  end
  appendGroups(front, "front-")
  appendGroups(rear, "rear-")
  return result
end

local function quoteRevision(vehicleData, groups)
  local rows = {currentTireSignature(vehicleData)}
  for _, group in ipairs(groups or {}) do
    table.insert(rows, string.format("%s:%0.2f:%s", group.id, group.subtotal, group.tireName))
  end
  return table.concat(rows, "|")
end

function M.buildUiData(inventoryId)
  local vehicleData = vehicleDataForInventory(inventoryId)
  if not vehicleData then
    return {available = false, message = "Vehicle not found."}
  end
  local provider = deepCopy(vehicleData.rlsTireProvider or {
    id = "rls-bundled",
    name = "RLS Tyre Wear and Thermals",
    version = "1.3.0",
    source = "bundled",
    apiVersion = 1,
    integrated = true,
  })
  local integrated = provider.integrated == true
  local groups = buildAxleGroups(inventoryId, vehicleData, false)
  local signature = currentTireSignature(vehicleData)
  local inspection = vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.tireInspection
  local inspected = inspection and inspection.signature == signature
  local total = 0
  for _, group in ipairs(groups) do total = total + group.subtotal end
  local available = isMaintenanceEnabled() and integrated and #groups > 0
  local message
  if not isMaintenanceEnabled() then
    message = "Maintenance Mode is not enabled."
  elseif not integrated then
    message = "The selected external tire provider does not expose the RLS integration API."
  elseif #groups == 0 then
    message = "Tire layout is not available yet. Retrieve or respawn this vehicle once."
  end
  return {
    available = available,
    message = message,
    provider = provider,
    inspected = inspected == true,
    inspectedAt = inspected and inspection.inspectedAt or nil,
    signature = signature,
    quoteRevision = quoteRevision(vehicleData, groups),
    axles = groups,
    replaceAllSubtotal = round(total, 2),
  }
end

function M.buildBusinessUiData(businessId, vehicleId)
  local vehicleData = businessVehicleData(businessId, vehicleId)
  if not vehicleData then return {available = false, message = "Fleet vehicle not found."} end
  M.sendContextForBusinessVehicle(businessId, vehicleId, false)
  local provider = deepCopy(vehicleData.rlsTireProvider or {
    id = "rls-bundled", name = "RLS Tyre Wear and Thermals", version = "1.3.0",
    source = "bundled", apiVersion = 1, integrated = true,
  })
  local groups = buildAxleGroups(vehicleId, vehicleData, true)
  local signature = currentTireSignature(vehicleData)
  local inspection = vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.tireInspection
  local inspected = inspection and inspection.signature == signature
  local total = 0
  for _, group in ipairs(groups) do total = total + group.subtotal end
  local integrated = provider.integrated == true
  local available = isMaintenanceEnabled() and integrated and #groups > 0
  local message
  if not isMaintenanceEnabled() then
    message = "Maintenance Mode is not enabled."
  elseif not integrated then
    message = "The selected external tire provider does not expose the RLS integration API."
  elseif #groups == 0 then
    message = "Tire layout is not available yet. Pull out or respawn this fleet vehicle once."
  end
  return {
    available = available, message = message, provider = provider, inspected = inspected == true,
    inspectedAt = inspected and inspection.inspectedAt or nil, signature = signature,
    quoteRevision = quoteRevision(vehicleData, groups), axles = groups, replaceAllSubtotal = round(total, 2),
  }
end

function M.inspectAll(inventoryId)
  inventoryId = tonumber(inventoryId)
  local uiData = M.buildUiData(inventoryId)
  if not uiData.available then
    return {ok = false, message = uiData.message or "Tire inspection is unavailable."}
  end
  local vehicleData = vehicleDataForInventory(inventoryId)
  vehicleData.maintenanceComputerState = type(vehicleData.maintenanceComputerState) == "table" and
                                           vehicleData.maintenanceComputerState or {revealed = {}, jobs = {}}
  vehicleData.maintenanceComputerState.tireInspection = {
    signature = uiData.signature,
    inspectedAt = os.time(),
  }
  markDirty(inventoryId)
  return {ok = true, completed = true, tireShop = M.buildUiData(inventoryId)}
end

function M.inspectBusiness(businessId, vehicleId)
  local uiData = M.buildBusinessUiData(businessId, vehicleId)
  if not uiData.available then
    return {ok = false, message = uiData.message or "Tire inspection is unavailable."}
  end
  local vehicleData = businessVehicleData(businessId, vehicleId)
  vehicleData.maintenanceComputerState = type(vehicleData.maintenanceComputerState) == "table" and
                                           vehicleData.maintenanceComputerState or {revealed = {}, jobs = {}}
  vehicleData.maintenanceComputerState.tireInspection = {signature = uiData.signature, inspectedAt = os.time()}
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  return {ok = true, completed = true, tireShop = M.buildBusinessUiData(businessId, vehicleId)}
end

local function payCheckout(amount, paymentContext)
  amount = tonumber(amount) or 0
  if paymentContext and paymentContext.skipPayment then
    return true
  end
  if paymentContext and paymentContext.mode == "businessAccount" then
    local account = career_modules_bank and career_modules_bank.getBusinessAccount and
                      career_modules_bank.getBusinessAccount(paymentContext.businessType, paymentContext.businessId) or nil
    if not account or not career_modules_bank.payFromAccount then
      return false, "Business account is unavailable."
    end
    if not career_modules_bank.payFromAccount({money = {amount = amount, canBeNegative = false}}, account.id,
      "Tire Replacement", "Fresh replacement tires") then
      return false, "Not enough funds in business account."
    end
    return true
  end
  local price = {money = {amount = amount, canBeNegative = false}}
  if not career_modules_payment or not career_modules_payment.canPay or not career_modules_payment.canPay(price) then
    return false, "Not enough money."
  end
  if not career_modules_payment.pay(price, {label = "Fresh replacement tires", tags = {"maintenance", "tires", "buying"}}) then
    return false, "Payment failed."
  end
  return true
end

local function refundCheckout(amount, paymentContext)
  amount = tonumber(amount) or 0
  if paymentContext and paymentContext.skipPayment then
    return true
  end
  if paymentContext and paymentContext.mode == "businessAccount" then
    local account = career_modules_bank and career_modules_bank.getBusinessAccount and
                      career_modules_bank.getBusinessAccount(paymentContext.businessType, paymentContext.businessId) or nil
    return account and career_modules_bank.rewardToAccount and
             career_modules_bank.rewardToAccount({money = {amount = amount}}, account.id, "Tire Replacement Refund",
               "Tire replacement could not be completed")
  end
  return career_modules_payment and career_modules_payment.reward and
           career_modules_payment.reward({money = {amount = amount}}, {
             label = "Tire replacement refund",
             tags = {"maintenance", "tires", "refund"},
           }, true)
end

local function selectedGroups(uiData, axleIds)
  local wanted = {}
  for _, id in ipairs(axleIds or {}) do wanted[tostring(id)] = true end
  local result = {}
  for _, group in ipairs(uiData.axles or {}) do
    if wanted[group.id] then
      table.insert(result, group)
      wanted[group.id] = nil
    end
  end
  if next(wanted) then
    return nil
  end
  return result
end

local function freshStateForWheels(wheels)
  local state = {schemaVersion = 1, wheels = {}}
  for _, wheel in ipairs(wheels or {}) do
    state.wheels[wheel.name] = freshWheelState()
  end
  return state
end

local function stateFromWheels(wheels)
  local state = {schemaVersion = 1, wheels = {}}
  for _, wheel in ipairs(wheels or {}) do
    state.wheels[tostring(wheel.name)] = {
      remaining = tireModel.clamp(wheel.remaining, 0, 1),
      flat = wheel.flat == true,
    }
  end
  return state
end

local function markLayoutWheelsFresh(vehicleData, groups)
  local wanted = {}
  for _, group in ipairs(groups or {}) do
    for _, wheel in ipairs(group.wheels or {}) do
      wanted[tostring(wheel.name)] = true
    end
  end
  for _, wheel in ipairs(vehicleData and vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    if wanted[tostring(wheel.name)] then
      wheel.remaining = 1
      wheel.flat = false
    end
  end
end

local function businessPartIsFitted(vehicleData, descriptor)
  local function walk(node)
    if type(node) ~= "table" then return false end
    local chosen = node.chosenPartName
    local candidatePath = node.partPath or
                            (type(node.path) == "string" and chosen and (node.path .. chosen) or nil)
    if chosen == descriptor.partOrigin and
       (not descriptor.partPath or candidatePath == descriptor.partPath) then
      return true
    end
    for _, child in pairs(node.children or {}) do
      if walk(child) then return true end
    end
    return false
  end
  return walk(vehicleData and vehicleData.config and vehicleData.config.partsTree)
end

local function replacePersonalParts(inventoryId, vehicleData, groups, rollback)
  local inventory = personalInventory()
  for _, group in ipairs(groups) do
    for _, descriptor in ipairs(group.parts) do
      local partId, oldPart = findPersonalPart(inventoryId, descriptor.partPath, descriptor.partOrigin,
        descriptor.containingSlot)
      if not oldPart then
        error("Installed tire part is no longer available: " .. tostring(descriptor.partOrigin))
      end
      rollback.personalParts[partId] = deepCopy(oldPart)
      setPartState(oldPart, stateFromWheels(group.wheels))
      oldPart.location = 0
      local newPart = deepCopy(oldPart)
      newPart.location = inventoryId
      newPart.partCondition = {integrityValue = 1, odometer = 0, visualValue = 1}
      setPartState(newPart, freshStateForWheels(group.wheels))
      local before = {}
      for id in pairs(inventory) do before[id] = true end
      career_modules_partInventory.addPartToInventory(newPart)
      for id in pairs(inventory) do
        if not before[id] then
          table.insert(rollback.addedPersonalIds, id)
          break
        end
      end
      vehicleData.partConditions = type(vehicleData.partConditions) == "table" and vehicleData.partConditions or {}
      vehicleData.partConditions[newPart.partPath] = deepCopy(newPart.partCondition)
      vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                             vehicleData.rlsTireStateByPartPath or {}
      vehicleData.rlsTireStateByPartPath[newPart.partPath] = freshStateForWheels(group.wheels)
    end
  end
  markLayoutWheelsFresh(vehicleData, groups)
  if career_modules_partInventory.onPartShoppingTransactionComplete then
    career_modules_partInventory.onPartShoppingTransactionComplete()
  end
end

local function replaceBusinessParts(inventoryId, vehicleData, groups, paymentContext, rollback)
  local businessInventory = career_modules_business_businessPartInventory
  if not businessInventory or not businessInventory.addPart then
    error("Business part inventory is unavailable.")
  end
  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  for _, group in ipairs(groups) do
    for _, descriptor in ipairs(group.parts) do
      if not businessPartIsFitted(vehicleData, descriptor) then
        error("The quoted fleet tire is no longer fitted: " .. tostring(descriptor.partOrigin))
      end
      local path = descriptor.partPath or ((descriptor.containingSlot or "") .. tostring(descriptor.partOrigin or ""))
      local slotPath = path:match("^(.*[/])[^/]+$") or descriptor.containingSlot
      local oldState = stateFromWheels(group.wheels)
      local partCondition = vehicleData.partConditions and vehicleData.partConditions[path] or
                              {integrityValue = 1, odometer = 0, visualValue = 1}
      local addedId = businessInventory.addPart({
        name = descriptor.partOrigin,
        vehicleModel = vehicleData.model or vehicleData.model_key or
                         (vehicleData.vehicleConfig and vehicleData.vehicleConfig.model_key),
        containingSlot = slotPath,
        slot = slotPath and (slotPath:match("/([^/]+)/$") or slotPath:match("/([^/]+)$")) or nil,
        partPath = path,
        partCondition = deepCopy(partCondition),
        rlsTireState = deepCopy(oldState),
      }, paymentContext.businessId)
      if not addedId then
        error("Could not return the removed tire to business inventory.")
      end
      table.insert(rollback.addedBusinessIds, addedId)
      vehicleData.partConditions = type(vehicleData.partConditions) == "table" and vehicleData.partConditions or {}
      vehicleData.partConditions[path] = {integrityValue = 1, odometer = 0, visualValue = 1}
      vehicleData.rlsTireStateByPartPath[path] = freshStateForWheels(group.wheels)
    end
  end
  markLayoutWheelsFresh(vehicleData, groups)
end

function M.checkout(inventoryId, axleIds, revision, paymentContext)
  inventoryId = tonumber(inventoryId)
  local uiData = M.buildUiData(inventoryId)
  if not uiData.available then
    return {ok = false, message = uiData.message or "Tire replacement is unavailable."}
  end
  if not uiData.inspected then
    return {ok = false, message = "Check all tires before replacing them."}
  end
  if tostring(revision or "") ~= tostring(uiData.quoteRevision or "") then
    return {ok = false, staleQuote = true, message = "Tire condition or pricing changed. Review the updated quote."}
  end
  local groups = selectedGroups(uiData, axleIds)
  if not groups or #groups == 0 then
    return {ok = false, message = "Select at least one axle."}
  end
  local total = 0
  for _, group in ipairs(groups) do total = total + group.subtotal end
  local paid, paymentError = payCheckout(total, paymentContext)
  if not paid then
    return {ok = false, message = paymentError or "Payment failed."}
  end

  local vehicleData = vehicleDataForInventory(inventoryId)
  local rollback = {
    vehiclePartConditions = deepCopy(vehicleData.partConditions),
    vehicleTireState = deepCopy(vehicleData.rlsTireStateByPartPath),
    maintenanceComputerState = deepCopy(vehicleData.maintenanceComputerState),
    personalParts = {},
    addedPersonalIds = {},
    addedBusinessIds = {},
  }
  local committed, commitError = xpcall(function()
    if paymentContext and paymentContext.mode == "businessAccount" then
      replaceBusinessParts(inventoryId, vehicleData, groups, paymentContext, rollback)
    else
      replacePersonalParts(inventoryId, vehicleData, groups, rollback)
    end
    vehicleData.maintenanceComputerState.tireInspection = nil
    partRevisions[inventoryId] = (tonumber(partRevisions[inventoryId]) or 0) + 1
    markDirty(inventoryId)
    if career_saveSystem and career_saveSystem.saveCurrent then
      career_saveSystem.saveCurrent({inventoryId})
    end
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId and
                    career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    M.sendContextForVehicle(vehId, true)
    applyFreshTiresOnVehId(vehId)
  end, debug.traceback)

  if not committed then
    vehicleData.partConditions = rollback.vehiclePartConditions
    vehicleData.rlsTireStateByPartPath = rollback.vehicleTireState
    vehicleData.maintenanceComputerState = rollback.maintenanceComputerState
    local inventory = personalInventory()
    for id, part in pairs(rollback.personalParts) do inventory[id] = part end
    for _, id in ipairs(rollback.addedPersonalIds) do inventory[id] = nil end
    for _, id in ipairs(rollback.addedBusinessIds) do
      if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.removePart then
        career_modules_business_businessPartInventory.removePart(id, paymentContext and paymentContext.businessId)
      end
    end
    if career_modules_partInventory.onPartShoppingTransactionComplete then
      career_modules_partInventory.onPartShoppingTransactionComplete()
    end
    refundCheckout(total, paymentContext)
    markDirty(inventoryId)
    if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
    if log then log("E", "tireSystem", "Tire checkout rolled back: " .. tostring(commitError)) end
    return {ok = false, message = "Tire replacement failed; payment was refunded."}
  end

  return {ok = true, completed = true, price = round(total, 2)}
end

function M.checkoutBusiness(businessType, businessId, vehicleId, axleIds, revision)
  if not career_modules_business_businessManager or
     not career_modules_business_businessManager.isPurchasedBusiness or
     not career_modules_business_businessManager.isPurchasedBusiness(businessType, businessId) then
    return {ok = false, message = "Business ownership could not be verified."}
  end
  local uiData = M.buildBusinessUiData(businessId, vehicleId)
  if not uiData.available then return {ok = false, message = uiData.message or "Tire replacement is unavailable."} end
  if not uiData.inspected then return {ok = false, message = "Check all tires before replacing them."} end
  if tostring(revision or "") ~= tostring(uiData.quoteRevision or "") then
    return {ok = false, staleQuote = true, message = "Tire condition or pricing changed. Review the updated quote."}
  end
  local groups = selectedGroups(uiData, axleIds)
  if not groups or #groups == 0 then return {ok = false, message = "Select at least one axle."} end
  local total = 0
  for _, group in ipairs(groups) do total = total + group.subtotal end
  local paymentContext = {mode = "businessAccount", businessType = businessType, businessId = businessId}
  local paid, paymentError = payCheckout(total, paymentContext)
  if not paid then return {ok = false, message = paymentError or "Payment failed."} end

  local vehicleData = businessVehicleData(businessId, vehicleId)
  local rollback = {
    vehiclePartConditions = deepCopy(vehicleData.partConditions),
    vehicleTireState = deepCopy(vehicleData.rlsTireStateByPartPath),
    maintenanceComputerState = deepCopy(vehicleData.maintenanceComputerState),
    addedBusinessIds = {}, personalParts = {}, addedPersonalIds = {},
  }
  local committed, commitError = xpcall(function()
    replaceBusinessParts(vehicleId, vehicleData, groups, paymentContext, rollback)
    vehicleData.maintenanceComputerState.tireInspection = nil
    local revisionKey = "b:" .. tostring(businessId) .. ":" .. tostring(vehicleId)
    partRevisions[revisionKey] = (tonumber(partRevisions[revisionKey]) or 0) + 1
    if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
    M.sendContextForBusinessVehicle(businessId, vehicleId, true)
    local vehId = career_modules_business_businessInventory.getSpawnedVehicleId and
                    career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId) or nil
    applyFreshTiresOnVehId(vehId)
  end, debug.traceback)

  if not committed then
    vehicleData.partConditions = rollback.vehiclePartConditions
    vehicleData.rlsTireStateByPartPath = rollback.vehicleTireState
    vehicleData.maintenanceComputerState = rollback.maintenanceComputerState
    for _, id in ipairs(rollback.addedBusinessIds) do
      if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.removePart then
        career_modules_business_businessPartInventory.removePart(id, businessId)
      end
    end
    refundCheckout(total, paymentContext)
    M.sendContextForBusinessVehicle(businessId, vehicleId, true)
    if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
    if log then log("E", "tireSystem", "Business tire checkout rolled back: " .. tostring(commitError)) end
    return {ok = false, message = "Tire replacement failed; payment was refunded."}
  end
  return {ok = true, completed = true, price = round(total, 2)}
end

function M.onVehicleSpawned(_, vehObj)
  if vehObj then
    lastContextSignatures[vehObj:getID()] = nil
    M.sendContextForVehicle(vehObj:getID(), true)
  end
end

function M.onVehicleSwitched(oldId, newVehId)
  local oldVehId = tonumber(oldId)
  local oldVeh = oldVehId and getObjectByID(oldVehId) or nil
  if oldVeh then
    oldVeh:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState(); rlsTireProvider.resetThermalsAndGrip() end")
  end
  local owner = newVehId and runtimeOwnersByVehId[tonumber(newVehId)] or nil
  if owner and owner.kind == "business" then
    M.sendContextForBusinessVehicle(owner.businessId, owner.vehicleId, true)
  elseif newVehId then
    M.sendContextForVehicle(newVehId, true)
  end
end

function M.onVehicleRemoved(inventoryId, vehId)
  local vehObj = vehId and getObjectByID(tonumber(vehId)) or nil
  if vehObj then vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState() end") end
  if vehId then
    runtimeOwnersByVehId[tonumber(vehId)] = nil
    lastContextSignatures[tonumber(vehId)] = nil
  end
end

function M.onInventoryPreRemoveVehicleObject(inventoryId, vehId)
  vehId = tonumber(vehId)
  local vehObj = vehId and getObjectByID(vehId) or nil
  if vehObj then
    vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState(); rlsTireProvider.resetThermalsAndGrip() end")
  end
  if vehId then
    runtimeOwnersByVehId[vehId] = nil
    lastContextSignatures[vehId] = nil
  end
end

function M.onPartShoppingStarted()
  local inventoryId = career_modules_inventory and career_modules_inventory.getCurrentVehicle and
                        career_modules_inventory.getCurrentVehicle() or nil
  local vehId = inventoryId and career_modules_inventory.getVehicleIdFromInventoryId and
                  career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  local vehObj = vehId and getObjectByID(vehId) or nil
  if vehObj then vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState() end") end
  local vehicleData = inventoryId and vehicleDataForInventory(inventoryId) or nil
  for _, wheel in ipairs(vehicleData and vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
    local _, part = findPersonalPart(inventoryId, wheel.partPath, wheel.partOrigin, wheel.containingSlot)
    if part then
      local wheelState = ensurePartWheelState(part, wheel.name, vehicleData)
      wheelState.remaining = tireModel.clamp(wheel.remaining, 0, 1)
      wheelState.flat = wheel.flat == true
      setPartState(part, partState(part))
    end
  end
end

local function installedPartMatchesWheel(descriptor, wheel)
  if descriptor.partPath and wheel.partPath == descriptor.partPath then
    return true
  end
  return descriptor.containingSlot and wheel.containingSlot == descriptor.containingSlot
end

function M.onPartShoppingPartsInstalled(inventoryId, installedParts)
  inventoryId = tonumber(inventoryId)
  local vehicleData = inventoryId and vehicleDataForInventory(inventoryId) or nil
  if not vehicleData or type(installedParts) ~= "table" then return end

  local changed = false
  for _, descriptor in ipairs(installedParts) do
    local lowerName = string.lower(tostring(descriptor.name or ""))
    if string.sub(lowerName, 1, 5) == "tire_" then
      local _, part = findPersonalPart(inventoryId, descriptor.partPath, descriptor.name,
        descriptor.containingSlot)
      if part then
        for _, wheel in ipairs(vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
          if installedPartMatchesWheel(descriptor, wheel) then
            local wheelState = ensurePartWheelState(part, wheel.name, vehicleData,
              descriptor.fromInventory ~= true)
            wheel.remaining = wheelState.remaining
            wheel.flat = wheelState.flat
            changed = true
          end
        end
      end
    end
  end

  if changed then
    maybeInvalidateInspection(vehicleData)
    markDirty(inventoryId)
  end
end

function M.onExperimentalMaintenanceModeChanged()
  sendAllContexts(true)
end

function M.onTrailerAttached()
  sendAllContexts(true)
end

function M.onPartShoppingTransactionComplete()
  for inventoryId in pairs(career_modules_inventory and career_modules_inventory.getVehicles and
                              career_modules_inventory.getVehicles() or {}) do
    -- Skip non-numeric ids (e.g. offroadRecovery:job-...) — partRevisions is keyed by number.
    local id = tonumber(inventoryId)
    if id then
      partRevisions[id] = (tonumber(partRevisions[id]) or 0) + 1
    end
  end
  sendAllContexts(true)
end

function M.onUpdate(dtReal, dtSim)
  contextTimer = contextTimer + (tonumber(dtSim) or tonumber(dtReal) or 0)
  if contextTimer < 1 then return end
  contextTimer = 0
  sendAllContexts(false)
end

function M.onCareerActive()
  local purchased = career_modules_business_businessManager and
                      career_modules_business_businessManager.getAllPurchasedBusinesses and
                      career_modules_business_businessManager.getAllPurchasedBusinesses() or {}
  for _, businessesById in pairs(purchased) do
    for businessId, owned in pairs(businessesById or {}) do
      if owned == true or type(owned) == "table" then
        for _, vehicleData in ipairs(career_modules_business_businessInventory and
                                       career_modules_business_businessInventory.getPulledOutVehicles and
                                       career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}) do
          local vehicleId = vehicleData and vehicleData.vehicleId
          local vehId = vehicleId and career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
          if vehId then M.registerBusinessVehicle(businessId, vehicleId, vehId) end
        end
      end
    end
  end
  sendAllContexts(true)
end

function M.onClientEndMission()
  for inventoryId in pairs(career_modules_inventory and career_modules_inventory.getVehicles and
                             career_modules_inventory.getVehicles() or {}) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId and
                    career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    local vehObj = vehId and getObjectByID(vehId) or nil
    if vehObj then vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState(); rlsTireProvider.resetThermalsAndGrip() end") end
  end
  for vehId in pairs(runtimeOwnersByVehId) do
    local vehObj = getObjectByID(vehId)
    if vehObj then
      vehObj:queueLuaCommand("if rlsTireProvider then rlsTireProvider.flushState(); rlsTireProvider.resetThermalsAndGrip() end")
    end
  end
  for inventoryId in pairs(burnoutOverrides) do burnoutOverrides[inventoryId] = nil end
end

local function normalizeWheelNameSet(wheelNames)
  local set = {}
  if type(wheelNames) ~= "table" then
    return set
  end
  for key, value in pairs(wheelNames) do
    if type(key) == "number" and type(value) == "string" and value ~= "" then
      set[value] = true
    elseif type(key) == "string" and key ~= "" and value then
      set[key] = true
    end
  end
  return set
end

local function refreshLiveTires(inventoryId)
  partRevisions[inventoryId] = (tonumber(partRevisions[inventoryId]) or 0) + 1
  markDirty(inventoryId)

  local vehId = career_modules_inventory.getVehicleIdFromInventoryId and
                  career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  if not vehId then
    return
  end
  M.sendContextForVehicle(vehId, true)
  applyFreshTiresOnVehId(vehId)
end

-- Freeroam+/cheats Insert recover: clear persisted tire wear/flats and reinflate live tires.
function M.forceFreshForVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  local vehicleData = vehicleDataForInventory(inventoryId)
  if not inventoryId or not vehicleData then
    return false
  end

  local inventory = personalInventory()
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == inventoryId then
      local state = partState(part)
      if type(state) == "table" and type(state.wheels) == "table" then
        for wheelName in pairs(state.wheels) do
          state.wheels[wheelName] = freshWheelState()
        end
        setPartState(part, state)
      end
    end
  end

  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  for _, state in pairs(vehicleData.rlsTireStateByPartPath) do
    if type(state) == "table" and type(state.wheels) == "table" then
      for wheelName in pairs(state.wheels) do
        state.wheels[wheelName] = freshWheelState()
      end
    end
  end
  if type(vehicleData.rlsTireLayout) == "table" and type(vehicleData.rlsTireLayout.wheels) == "table" then
    for _, wheel in ipairs(vehicleData.rlsTireLayout.wheels) do
      wheel.remaining = 1
      wheel.flat = false
    end
  end

  refreshLiveTires(inventoryId)
  return true
end

-- Roadside selective repair: refresh only the named wheels.
function M.forceFreshWheels(inventoryId, wheelNames)
  inventoryId = tonumber(inventoryId)
  local vehicleData = vehicleDataForInventory(inventoryId)
  local wanted = normalizeWheelNameSet(wheelNames)
  if not inventoryId or not vehicleData or not next(wanted) then
    return false
  end

  local touched = false
  local inventory = personalInventory()
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == inventoryId then
      local state = partState(part)
      if type(state) == "table" and type(state.wheels) == "table" then
        local partTouched = false
        for wheelName in pairs(state.wheels) do
          if wanted[wheelName] then
            state.wheels[wheelName] = freshWheelState()
            partTouched = true
            touched = true
          end
        end
        if partTouched then
          setPartState(part, state)
        end
      end
    end
  end

  vehicleData.rlsTireStateByPartPath = type(vehicleData.rlsTireStateByPartPath) == "table" and
                                         vehicleData.rlsTireStateByPartPath or {}
  for _, state in pairs(vehicleData.rlsTireStateByPartPath) do
    if type(state) == "table" and type(state.wheels) == "table" then
      for wheelName in pairs(state.wheels) do
        if wanted[wheelName] then
          state.wheels[wheelName] = freshWheelState()
          touched = true
        end
      end
    end
  end
  if type(vehicleData.rlsTireLayout) == "table" and type(vehicleData.rlsTireLayout.wheels) == "table" then
    for _, wheel in ipairs(vehicleData.rlsTireLayout.wheels) do
      if type(wheel) == "table" and wanted[tostring(wheel.name or "tire")] then
        wheel.remaining = 1
        wheel.flat = false
        touched = true
      end
    end
  end

  if not touched then
    return false
  end
  refreshLiveTires(inventoryId)
  return true
end

return M
