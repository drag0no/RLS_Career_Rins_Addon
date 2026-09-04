-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local moduleVersion = 42
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager, dTutorial, dMaterialContracts
local step

-- Reloads / activate races can leave these upvalues nil while career is already
-- active and markerInteraction is asking for POIs. Rebind from globals on demand.
local function bindDeliveryDeps()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTasklist = career_modules_delivery_tasklist
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dTutorial = career_modules_delivery_tutorial
  dMaterialContracts = career_modules_delivery_materialContractManager
  step = util_stepHandler
  return dParcelManager and dProgress and dVehicleTasks and dTutorial
end

M.onCareerActivated = function()
  bindDeliveryDeps()
end

-- World drop-offs are baked into gameplay_rawPois once. Pause unsticks them only
-- because nearbyActivities calls clear() after career/cargo is actually ready.
-- Rebuild on the next updates so we do not cache an empty list from the first pass.
local deliveryPoiRefreshFrames = nil
local deliveryPoiRefreshTries = 0
local MAX_DELIVERY_POI_REFRESH_TRIES = 90
local lastInteractivePoiKey = nil
local refreshDeliveryWorldPoisIfChanged

local function requestDeliveryPoiRefresh(resetTries)
  deliveryPoiRefreshFrames = 2
  if resetTries then
    deliveryPoiRefreshTries = 0
  end
end

local function refreshDeliveryWorldPoisIfPending()
  if not deliveryPoiRefreshFrames then return end
  deliveryPoiRefreshFrames = deliveryPoiRefreshFrames - 1
  if deliveryPoiRefreshFrames > 0 then return end
  deliveryPoiRefreshFrames = nil
  deliveryPoiRefreshTries = deliveryPoiRefreshTries + 1
  if deliveryPoiRefreshTries > MAX_DELIVERY_POI_REFRESH_TRIES then
    return
  end
  if not bindDeliveryDeps() then
    deliveryPoiRefreshFrames = 2
    return
  end
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
end
M.requestDeliveryPoiRefresh = requestDeliveryPoiRefresh

local deliveryGameTime = 0
local deliveryGameTimePaused = false

local deliveryModeActive = false
local deliveryAbandonPenaltyFactor = 0.1
M.getDeliveryAbandonPenaltyFactor = function() return deliveryAbandonPenaltyFactor end

local function fireCargoAbandonedNotification(penaltyAmount)
  if not penaltyAmount or penaltyAmount >= 0 then return end
  if not ui_phone_layout and extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  if ui_phone_layout and ui_phone_layout.fireNotification then
    ui_phone_layout.fireNotification("logistics.cargoAbandoned", {
      title = "Cargo Abandoned",
      message = string.format("Penalty: $%0.2f", -penaltyAmount),
      kind = "warning",
      ttl = 8,
      source = "Logistics",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
    })
  end
end



-- Career general systems interaction (save/load, level setup)

local saveFile = "logisticsDatabase.json"
local loadData = {}
local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = (not outdated and savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}

  loadData = data
  dProgress.setProgress(loadData.progress)
  dParcelMods.setProgress(loadData.parcelModProgress)
  loadData.facilities = loadData.facilities or {}
  loadData.settings = data.settings or {}

  if loadData.settings.automaticRoute == nil then
    loadData.settings.automaticRoute = true
  end

  deliveryGameTime = loadData.general and loadData.general.gameTime or deliveryGameTime
  if loadData.general and loadData.general.osTime then
    log("I","",string.format("Save data age: %ds",os.time() - loadData.general.osTime))
    -- delete save data if the save is older than an hour
    if os.time() - loadData.general.osTime > 3600 then
      log("I","",string.format("Save data is older than 3600s (%d), wiping cargo and facility timers",os.time() - loadData.general.osTime))
      loadData.cargo = {}
      for key, fac in pairs(loadData.facilities) do
        fac.logisticGenerators = nil
      end
    end
  end

  --log("I","",string.format("Loaded save data for logistics: %d cargo", #loadData.cargo))
end
M.loadSaveData = loadSaveData
local function saveableCargoFilter(cargo)
  -- Contract material is represented by the persistent reservation ledger.
  -- Vehicle/pending cargo intentionally returns to that reservation on load.
  if cargo.data and cargo.data.materialContractId then return false end
  return cargo.offerExpiresAt > M.time() and cargo.location.type == "facilityParkingspot"
end
local function onSaveCurrentProfile(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  local saveData = {
    general = {},
    penalty = M.getDeliveryModePenalty(),
    parcels = {},
    vehicleOffers = {},
    facilities = {},
    settings = loadData.settings or {},
    materialContracts = dMaterialContracts and dMaterialContracts.serialize() or nil,
  }

  -- general data
  saveData.general.gameTime = M.time()
  saveData.general.osTime = os.time()
  saveData.progress = dProgress.getProgress()
  saveData.parcelModProgress = dParcelMods.getProgress()

  -- facility data

  -- parcels
  local saveableCargo = dParcelManager.getAllCargoCustomFilter(saveableCargoFilter)
  local maxGroupId = 0
  local groupMap = {}
  for _, cargo in ipairs(saveableCargo) do
    local elem = {
      rewards = cargo.rewards,
      templateId = cargo.templateId,
      name = cargo.name,
      type = cargo.type,
      slots = cargo.slots,
      offerExpiresAt = cargo.offerExpiresAt,
      location = cargo.location,
      origin = cargo.origin,
      destination = cargo.destination,
      data = cargo.data,
      generatorLabel = cargo.generatorLabel,
      modifiers = cargo.modifiers,
      generatedAtTimestamp = cargo.generatedAtTimestamp,
      weight = cargo.weight,
      density = cargo.density,
      groupSeed = cargo.groupSeed,
      automaticDropOff = cargo.automaticDropOff,
      organization = cargo.organization,
      materialType = cargo.materialType,
      merge = cargo.merge,
      sourceStorage = cargo.sourceStorage,
      hiddenInFacility = cargo.hiddenInFacility,
    }
    if not groupMap[cargo.groupId] then
      maxGroupId = maxGroupId + 1
      groupMap[cargo.groupId] = maxGroupId
    end
    elem.groupId = groupMap[cargo.groupId]
    table.insert(saveData.parcels, elem)
  end
  saveData.general.maxGroupId = maxGroupId

  local saveableVehicleOffers = dVehOfferManager.getAllOfferUnexpired()
  for _, offer in ipairs(saveableVehicleOffers) do
    -- vehicle offers dont need to be trunkated/cut before saving
    table.insert(saveData.vehicleOffers, offer)
  end

  -- facility data
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local elem = {
      logisticGenerators = {},
      progress = facility.progress,
      materialStorages = facility.materialStorages,
    }
    for i, generator in ipairs(facility.logisticGenerators or {}) do
      elem.logisticGenerators[i] = {
        nextGenerationTimestamp = generator.nextGenerationTimestamp
      }
    end
    saveData.facilities[facility.id] = elem
  end

  -- save the data to file
  career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
end
M.onSaveCurrentProfile = onSaveCurrentProfile

local function onCareerActive(active)
  if not active then return end
  if not bindDeliveryDeps() then
    log("E", "delivery", "onCareerActive: delivery deps not ready (parcelManager missing)")
    return
  end
  loadSaveData()
  map.assureLoad()
  dGenerator.setup(loadData)
  if dMaterialContracts then
    dMaterialContracts.setup(loadData.materialContracts)
  end
  requestDeliveryPoiRefresh(true)
end
M.onCareerActive = onCareerActive


local fast = 1
M.time = function() return deliveryGameTime end



-- vehicle management

local function getVehicleName(vehId)
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local niceVehicleName = inventoryId and career_modules_inventory.getVehicleNiceNameTranslated(inventoryId)
  if type(niceVehicleName) == "string" and niceVehicleName ~= "" then
    return niceVehicleName
  end
  return core_locales.contextTranslate("ui.career.delivery.general.vehicleFallback", {id = vehId})
end
M.getVehicleName = getVehicleName


local mostRecentCargoContainerData = {}
local nearbyRadius = 40*40
local sortByVehIdAndContainerId = function(a,b) if a.vehId == b.vehId then return a.containerId < b.containerId else return a.vehId < b.vehId end end
local warnedInvalidCargoContainerResponses = {}
local function getCargoContainerListFromBridge(response, vehId)
  if type(response) == "table" and type(response[1]) == "table" then
    return response[1]
  end

  if not warnedInvalidCargoContainerResponses[vehId] then
    warnedInvalidCargoContainerResponses[vehId] = true
    local reason = type(response) == "table" and response.failReason or nil
    log("W", "", string.format(
      "Ignoring invalid cargo-container response from vehicle %s%s.",
      tostring(vehId),
      reason and (": " .. tostring(reason)) or ""
    ))
  end
  return {}
end

local function getNearbyVehicleCargoContainers(callback)
  if not core_vehicleBridge then return {} end
  local vehCargoData = {}
  local playerPos = getPlayerVehicle(0)
  playerPos = playerPos and playerPos:getPosition() or core_camera.getPosition()
  local vehs = {}
  local refNodeClusterIdByVehId = {}
  local footprintSet = {}
  if overhaul_playerVehicles and overhaul_playerVehicles.fillInteractionVehicleIds then
    local footprint = {}
    overhaul_playerVehicles.fillInteractionVehicleIds(footprint)
    for i = 1, #footprint do
      footprintSet[footprint[i]] = true
    end
  end
  for vehId, veh in activeVehiclesIterator() do
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false then
      local nearCab = playerPos and (playerPos-veh:getPosition()):squaredLength() < nearbyRadius
      if footprintSet[vehId] or nearCab then
        vehCargoData[vehId] = -1
        vehs[vehId] = veh
        refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
      end
    end
  end
  for vehId, veh in pairs(vehs) do

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      vehCargoData[vehId] = {}

      for _, container in ipairs(getCargoContainerListFromBridge(vehCargoContainerData, vehId)) do
        if type(container) ~= "table" or container.id == nil then
          local warningKey = "container:" .. tostring(vehId)
          if not warnedInvalidCargoContainerResponses[warningKey] then
            warnedInvalidCargoContainerResponses[warningKey] = true
            log("W", "", string.format("Skipping malformed cargo container from vehicle %s: %s", tostring(vehId), dumps(container)))
          end
          goto continue
        end

        local cargoTypes = type(container.cargoTypes) == "table" and container.cargoTypes or {}
        local capacity = tonumber(container.capacity) or 0
        local vehName = getVehicleName(vehId)
        local elem = {
          vehId = vehId,
          containerId = container.id,
          location = {type = "vehicle", vehId = veh:getID(), containerId = container.id},
          vehName = vehName,
          name = container.name or "Unnamed Container",
          moveToLabel = vehName .. " " .. (container.name or "Unnamed Container"),
          cargoTypesLookup = tableValuesAsLookupDict(cargoTypes),
          cargoTypesString = table.concat(cargoTypes,", "),
          totalCargoSlots = capacity,
          usedCargoSlots = 0,
          transientCargoSlots = 0,
          freeCargoSlots = capacity,
          refNodeClusterId = refNodeClusterIdByVehId[vehId],
          clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId),
          position = (container.nodeId and veh:getNodePosition(container.nodeId) or vec3(0,0,0)) + veh:getPosition(),
        }


        if not elem.clusterId or elem.refNodeClusterId == elem.clusterId then
          elem.attachmentStatus = "attached"
        else
          local dist = (elem.position-veh:getPosition()):length()
          if dist < 10 then
            elem.attachmentStatus = "nearby"
          else
            elem.attachmentStatus = "lost"
          end
        end
        elem.rawCargo = dParcelManager.getAllCargoForLocation(elem.location)

        elem.transientCargo = dParcelManager.getTransientMovesForTargetLocationWithCargo(elem.location)


        --for key, amount in pairs(elem.totalCargoSlots) do
        --  elem.usedCargoSlots[key] = 0
        --end
        for _, cargo in ipairs(elem.rawCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        for _, cargo in ipairs(elem.transientCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.transientCargoSlots = elem.transientCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        table.insert(vehCargoData[vehId], elem)
        ::continue::
      end

      -- check if all cargo was sent
      for key, val in pairs(vehCargoData) do
        if val == -1 then return end
      end

      -- if we're still here, call the function callback to send data back
      local ret = {}
      for _, list in pairs(vehCargoData) do
        for _, elem in ipairs(list) do
          table.insert(ret, elem)
        end
      end
      table.sort(ret, sortByVehIdAndContainerId)
      mostRecentCargoContainerData = ret
      callback(ret)

    end, "getCargoContainers")
  end
  if not next(vehs) then
    callback({})
  end

end
M.getNearbyVehicleCargoContainers = getNearbyVehicleCargoContainers
M.getMostRecentCargoContainerData = function() return mostRecentCargoContainerData end


local function defaultDelayCallback(data)
  local maxDelay = 0
  for _, delay in pairs(data) do
    maxDelay = math.max(delay, maxDelay)
  end
  if maxDelay > 0 then
    maxDelay = math.max(maxDelay, 1)
    -- make
    local sequence = {
      step.makeStepWait(maxDelay+0.5),
      step.makeStepReturnTrueFunction(function()
        for vehId, data in pairs(data) do
          local veh = scenetree.findObjectById(vehId)
          core_vehicleBridge.executeAction(veh, 'setFreeze', false)
        end
        gameplay_markerInteraction.setForceReevaluateOpenPrompt()
      return true
      end
      )
    }
    step.startStepSequence(sequence, callback)
    -- add loading progress bar
    guihooks.trigger("OpenSimpleDelayPopup",{timer=maxDelay, heading=_tr("ui.career.delivery.general.loadingCargo")})
  else
    -- 1s delay, no freeze
    for vehId, data in pairs(data) do
      local veh = scenetree.findObjectById(vehId)
      core_vehicleBridge.executeAction(veh, 'setFreeze', false)
    end
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end
  log("I","",string.format("%0.2fs delay after adjusting weights for cargo.", maxDelay))
end

local updateWeightsScheduled = false
local rememberedCargoWeightVehicleIds = {}

local function isUnicycle(veh)
  return veh and veh.getJBeamFilename and veh:getJBeamFilename() == "unicycle"
end

local function rememberCargoWeightVehicle(vehId)
  vehId = tonumber(vehId) or vehId
  if vehId then
    rememberedCargoWeightVehicleIds[vehId] = true
  end
end

local function rememberCurrentCargoWeightVehicles()
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles() or {}) do
    if cargo.location and cargo.location.vehId then
      rememberCargoWeightVehicle(cargo.location.vehId)
    end
  end
end

local function collectCargoWeightVehicleIds()
  local vehIds = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh and not isUnicycle(veh) and veh.playerUsable ~= false then
      vehIds[vehId] = true
    end
  end
  for vehId in pairs(rememberedCargoWeightVehicleIds) do
    vehIds[vehId] = true
  end
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles() or {}) do
    if cargo.location and cargo.location.vehId then
      vehIds[cargo.location.vehId] = true
    end
  end
  for _, container in ipairs(mostRecentCargoContainerData or {}) do
    if container.vehId then
      vehIds[container.vehId] = true
    end
  end
  return vehIds
end

M.requestUpdateContainerWeights = function() updateWeightsScheduled = true end
M.rememberCargoWeightVehicle = rememberCargoWeightVehicle
M.rememberCurrentCargoWeightVehicles = rememberCurrentCargoWeightVehicles
local function updateContainerWeights(delayCallback)
  if not updateWeightsScheduled then
    return
  end
  delayCallback = delayCallback or defaultDelayCallback
  updateWeightsScheduled = false
  log("I","","updateContainerWeights...")
  local updatePerVehicle = {}
  for vehId in pairs(collectCargoWeightVehicleIds()) do
    local veh = scenetree.findObjectById(vehId)
    if veh and not isUnicycle(veh) then
      updatePerVehicle[vehId] = {}
    end
  end
  rememberedCargoWeightVehicleIds = {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    local vehId = cargo.location and cargo.location.vehId
    if vehId then
      updatePerVehicle[vehId] = updatePerVehicle[vehId] or {}
      updatePerVehicle[vehId][cargo.location.containerId] = updatePerVehicle[vehId][cargo.location.containerId] or {
        volume = 0,
        density = 1,
        containerId = cargo.location.containerId
      }
      if not cargo.weight then log("W","","No weight on cargo? " .. dumps(cargo.name)) dump(cargo) end

      if cargo.type == "parcel" then
        -- add up load/weight
        updatePerVehicle[vehId][cargo.location.containerId].volume = updatePerVehicle[vehId][cargo.location.containerId].volume + (cargo.weight or 0)
      end

      if cargo.type == "fluid" or cargo.type == "dryBulk" or cargo.type == "cement" or cargo.type == "cash" then
        -- add up volume
        updatePerVehicle[vehId][cargo.location.containerId].volume = updatePerVehicle[vehId][cargo.location.containerId].volume + (cargo.slots or 0)
        -- only keep one density, since all cargo in one container have the same density
        updatePerVehicle[vehId][cargo.location.containerId].density = (cargo.weight/cargo.slots or 1)
      end
    end
  end
  --if next(updatePerVehicle) then
  for vehId, data in pairs(updatePerVehicle) do
    local veh = scenetree.findObjectById(vehId)
    if veh then
      core_vehicleBridge.executeAction(veh, "setCargoContainers", updatePerVehicle[vehId] or {}, "updateAll")
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)

      if next(updatePerVehicle[vehId]) then
        for _, con in pairs(updatePerVehicle[vehId]) do
          log("I","",string.format("Container %d => volume %0.1f | density: %0.1f",con.containerId, con.volume or 0, con.density or 1))
        end
      else
        log("I","",string.format("Vehicle %s => emptied all cargo containers", tostring(vehId)))
      end
    end
  end

  -- check loading delay
  local delayData = {}
  for vehId, data in pairs(updatePerVehicle) do
    if scenetree.findObjectById(vehId) then
      delayData[vehId] = -1
    end
  end

  for vehId, _ in pairs(delayData) do
    local veh = scenetree.findObjectById(vehId)
    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      local maxForContainer = 0
      for _, container in ipairs(getCargoContainerListFromBridge(vehCargoContainerData, vehId)) do
        maxForContainer = math.max(maxForContainer, tonumber(container.reachTargetTimeRemaining) or 0)
      end
      delayData[vehId] = maxForContainer


      for key, val in pairs(delayData) do
        if val == -1 then return end
      end
      delayCallback(delayData)

    end, "getCargoContainers")
  end
  if not next(delayData) then
    delayCallback(delayData)
  end

end
M.updateContainerWeights = updateContainerWeights


local colorForAttachmentDebug = {
  attached = ColorF(0.2,1,0.2, 0.75),
  nearby = ColorF(1,1,0.2, 0.75),
  lost = ColorF(1,0.2,0.2, 0.75),
}
local tickTimer = 0
M.setDeliveryTimePaused = function(paused) deliveryGameTimePaused = paused end
M.onUpdate = function(dtReal, dtSim, dtRaw)
  profilerPushEvent("Delivery DeliveryManager")
  refreshDeliveryWorldPoisIfPending()
  if refreshDeliveryWorldPoisIfChanged then
    refreshDeliveryWorldPoisIfChanged()
  end
  -- update game time
  --if freeroam_bigMapMode.bigMapActive() and not freeroam_bigMapMode.isTransitionActive() and not deliveryGameTimePaused then
    --deliveryGameTime = deliveryGameTime + dtReal * fast
  --else
  --end
  if not deliveryGameTimePaused then
    deliveryGameTime = deliveryGameTime + dtSim * fast
  end

  -- handle penalty from previous save
  if loadData.penalty and next(loadData.penalty) then
    local anyValue = false
    for key, value in pairs(loadData.penalty) do
      if value ~= 0 then
        anyValue = true
      end
    end
    if anyValue then
      fireCargoAbandonedNotification(loadData.penalty.money)
      career_modules_playerAttributes.addAttributes(loadData.penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
    end
    loadData.penalty = nil
  end

  tickTimer = tickTimer + dtSim
  if tickTimer > 1 then
    M.getNearbyVehicleCargoContainers(nop)
    tickTimer = tickTimer - 1
  end

  -- check if container weights need to be updated, only if unpauses
  if dtSim > 10e-10 then
    M.updateContainerWeights()
  end

  -- debug display for cargo boxes
  --[[
  if deliveryModeActive then
    for _, container in ipairs(mostRecentCargoContainerData) do
      simpleDebugText3d(container.name, container.position, 0.15, colorForAttachmentDebug[container.attachmentStatus])
    end
  end
  ]]

  profilerPopEvent("Delivery DeliveryManager")
end


local function addInteractivePoi(list, id, field, elem)
  if not list[id] then list[id] = {dropOffs = {}, pickUps = {}, vehicles = {}, materialContracts = {}} end
  table.insert(list[id][field], elem)
end
local function getInteractivePois()
  if not bindDeliveryDeps() then
    return {}, {}
  end
  local interactiveParkingSpots = {}
  local targetFacilityIds = {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    local acceptingContracts = cargo.data and cargo.data.materialContractId and dMaterialContracts
      and dMaterialContracts.getContractsAcceptingMaterial(cargo.materialType) or nil
    if acceptingContracts and #acceptingContracts > 0 then
      local addedPaths = {}
      for _, contract in ipairs(acceptingContracts) do
        local destination = contract.destination
        if destination and destination.type == "facilityParkingspot" and not addedPaths[destination.psPath] then
          addInteractivePoi(interactiveParkingSpots, destination.psPath, "dropOffs", cargo)
          addedPaths[destination.psPath] = true
          if destination.facId then targetFacilityIds[destination.facId] = true end
        end
      end
    elseif cargo.destination.type == "facilityParkingspot" then
      addInteractivePoi(interactiveParkingSpots, cargo.destination.psPath, "dropOffs", cargo)
      if cargo.destination.facId then
        targetFacilityIds[cargo.destination.facId] = true
      end
    elseif cargo.destination.type == "multi" then
      for _, dest in ipairs(cargo.destination.destinations) do
        addInteractivePoi(interactiveParkingSpots, dest.psPath, "dropOffs", cargo)
      end
    end
  end

  for _, cargo in ipairs(dParcelManager.getTransientMoveCargo()) do
    local locPsPath = cargo.location.psPath
    addInteractivePoi(interactiveParkingSpots, locPsPath, "pickUps", cargo)
  end

  -- figure out which facilities need to be active in order to drop of vehicles.
  local trailerTargetDestinations = dVehicleTasks.getTargetDestinationsForActiveTasks()
  for _, destination in ipairs(trailerTargetDestinations) do
    targetFacilityIds[destination.facId] = true
    addInteractivePoi(interactiveParkingSpots, destination.psPath, "vehicles", "vehicle")
  end

  for _, activeContract in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
    if activeContract.status == "active" and activeContract.origin
      and (activeContract.loadableAmount or 0) > 0 then
      addInteractivePoi(interactiveParkingSpots, activeContract.origin.psPath, "materialContracts", activeContract)
      targetFacilityIds[activeContract.origin.facId] = true
    end
  end

  return interactiveParkingSpots, targetFacilityIds
end

-- Pause unsticks drop-offs by clearing this cache. Any change to parcel, vehicle,
-- or trailer interactive spots must do the same or the world markers stay stale.
refreshDeliveryWorldPoisIfChanged = function()
  if not bindDeliveryDeps() then return end
  local spots = getInteractivePois()
  local keys = {}
  for path, _ in pairs(spots) do
    keys[#keys + 1] = path
  end
  table.sort(keys)
  local key = table.concat(keys, "|")
  if key == lastInteractivePoiKey then return end
  lastInteractivePoiKey = key
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
end

-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  if not bindDeliveryDeps() then
    requestDeliveryPoiRefresh()
    return
  end

  --local nearbyVehicles = M.getNearbyVehicleCargoContainers()
  local interactiveParkingSpots, targetFacilityIds = getInteractivePois()
  local isCargoDeliveryTutorialActive = dTutorial.isCargoDeliveryTutorialActive()
  local addedDropOff = false

  for _, fac in ipairs(freeroam_facilities.getFacilitiesByType("deliveryProvider") or {}) do
    -- only process facilities if the facility is visible
    local includeFac = dProgress.isFacilityVisible(fac.id, isCargoDeliveryTutorialActive) or targetFacilityIds[fac.id]

    if includeFac then
      local totalCargoCount = 0
      local lastPsPos = nil

      -- look up all relevant parking spots for this facility
      local spotsForThisFacLookup = {}

      for name, ap in pairs(fac.accessPointsByName or {}) do
        local ps = ap.ps
        -- Loaner-only pads are not cargo inspect spots; skip walking markers unless
        -- the player has active cargo business at this exact stall.
        local isLoanerOnlySpot = ap.isLoanerVehicleSpot and not ap.isInspectSpot
        local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
        local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}
        local cargoCount = #dParcelManager.getAllCargoForLocationUnexpiredUndelivered(loc)
        local canInspectCargo = ap.isInspectSpot
        totalCargoCount = totalCargoCount + cargoCount
        lastPsPos = ps.pos
        local icon = "poi_pickup_round"
        if interactiveParkingSpots[ps:getPath()] then
          icon = "poi_dropoff_round"
          addedDropOff = true
        end

        local focus = interactiveParkingSpots[ps:getPath()] ~= nil
        local elem = {
          id = id,
          data = {
            type = "logisticsParking",
            facId = fac.id,
            psPath = ps:getPath(),
            canInspectCargo = canInspectCargo,
            hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false,
            hasMaterialContract = interactiveParkingSpots[ps:getPath()]
              and next(interactiveParkingSpots[ps:getPath()].materialContracts) ~= nil or false,
          },
          markerInfo = {
            -- only include parking marker if there is an action
            parkingMarker = (interactiveParkingSpots[ps:getPath()] or (not isLoanerOnlySpot and (cargoCount > 0 or canInspectCargo))) and {path = ps:getPath(), pos = ps.pos, rot = ps.rot, scl = ps.scl, icon = icon, focus = focus} or nil,
          }
        }
        --print(string.format("including: %s-%s (%s). visible: %s, target: %s",
        --  fac.id, ps.id,
        --  dParcelManager.getLocationLabelShort({type="facilityParkingspot", facId = fac.id, psPath = ps:getPath()}),
        --  dumps(dProgress.isFacilityVisible(fac.id)),
        --  dumps(targetFacilityIds[fac.id] and true or false)
        --  ))
        if dCargoScreen.isCargoScreenOpen() then
          elem.markerInfo.bigmapMarker = {pos = ps.pos, name = _tr("ui.career.delivery.general.pickupPrefix") .. _tr(fac.name), icon = icon}
        else
          if interactiveParkingSpots[ps:getPath()] then

            local tasks = {}
            if next(interactiveParkingSpots[ps:getPath()].dropOffs) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverCargoItemsHere", {count = #interactiveParkingSpots[ps:getPath()].dropOffs}))
            end
            if next(interactiveParkingSpots[ps:getPath()].pickUps) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.pickUpCargoItemsHere", {count = #interactiveParkingSpots[ps:getPath()].pickUps}))
            end
            if next(interactiveParkingSpots[ps:getPath()].vehicles) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverVehiclesHere", {count = #interactiveParkingSpots[ps:getPath()].vehicles}))
            end
            if next(interactiveParkingSpots[ps:getPath()].materialContracts) then
              for _, contract in ipairs(interactiveParkingSpots[ps:getPath()].materialContracts) do
                table.insert(tasks, string.format("Load %s - %d %s remaining", _tr(contract.materialName), math.floor((contract.remainingAmount or 0) + 0.5), contract.units or "L"))
              end
            end

            local desc = table.concat(tasks, '<br/>')
            elem.markerInfo.bigmapMarker = {
              pos = ps.pos,
              name = dParcelManager.getLocationLabelShort(loc),
              description = desc,
              icon = "poi_dropoff_round",
              previews = {fac.preview},
              thumbnail = fac.preview,
            }
          end
        end
        if interactiveParkingSpots[ps:getPath()] or (not isLoanerOnlySpot and (canInspectCargo or dCargoScreen.isCargoScreenOpen())) then
          --dump(string.format("%s -> %s", fac.name, name))
          --dumpz(ap, 1)
          table.insert(elements, elem)
        end
      end
      --[[
      -- add trailer spots in a separate entry.
      if dCargoScreen.isCargoScreenOpen() then
        for _, ps in ipairs(fac.trailerSpots) do

          local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
          local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}

          local icon = "poi_pickup_round"
          if interactiveParkingSpots[ps:getPath()] then
            icon = "poi_dropoff_round"
          end

          local elem = {
            id = id,
            data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false },
            markerInfo = {
              bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
            }
          }
          table.insert(elements, elem)

        end

     end
]]
      -- one POI for the whole facility to display on bigmap under labourer branch.
      if not dCargoScreen.isCargoScreenOpen() then
        if dProgress.isFacilityUnlocked(fac.id) and next(fac.logisticTypesProvided) then
          local id = string.format("logisticsFacility-%s", fac.id)
          local elems = {}
          if fac.doors and next(fac.doors) then
            freeroam_facilities.walkingMarkerFormatFacility(fac, elems)
          end

          local pos = lastPsPos
          for name, ap in pairs(fac.accessPointsByName or {}) do
            if ap.isInspectSpot then
              pos = ap.ps.pos
            end
          end

          local elem = {
            id = id,
            data = {type = "logisticsOffice", facId = fac.id},
            markerInfo = {
              walkingMarker = next(elems) and elems[1].markerInfo.walkingMarker or nil,
              bigmapMarker = {pos = pos, name = _tr(fac.name), description = core_locales.contextTranslate(totalCargoCount ~= 1 and "ui.career.delivery.general.facilityItemsAvailablePlural" or "ui.career.delivery.general.facilityItemsAvailableSingular", {description = _tr(fac.description), count = totalCargoCount}), icon="poi_delivery_round", previews = {fac.preview}, thumbnail = fac.preview,} or nil
            }
          }
          table.insert(elements, elem)
        end
      end
    end
  end
  if next(interactiveParkingSpots) and not addedDropOff then
    requestDeliveryPoiRefresh()
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel



local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "logisticsOffice" then
      local data = {
        icon = "poi_delivery_round",
        heading = dGenerator.getFacilityById(elem.facId).name,
        preheadings = {_tr("ui.career.delivery.general.logisticsOffice")},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {{
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.cargoOverview")
        },{
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.noCargoPickup")
        }},
        buttonLabel = _tr("ui.career.delivery.general.inspectCargo"),
        buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId) end
      }
      table.insert(activityData, data)
    elseif elem.type == "logisticsParking" then

      -- cargo menu button
      local loc = {type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath}
      local poiTemplate = {
        icon = "poi_pickup_round",
        preheadings =  {dParcelManager.getLocationLabelShort({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath})},
        props = {},
        sorting = {
          type = elem.type,
          id = elem.id
        },
      }

      -- dropoff data and props
      local psPos = dGenerator.getParkingSpotByPath(elem.psPath).pos
      local dropOffableCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0,
        cement = 0,
        cash = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.rawCargo) do
          local add = 1
          local type = cargo.type
          local isContractCargo = cargo.data and cargo.data.materialContractId and dMaterialContracts
          local acceptsContractMaterial = isContractCargo
            and dMaterialContracts.getMaterialDeliveryCapacity(cargo.materialType, {
              type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath
            }) > 0
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          if acceptsContractMaterial then
            dropOffableCargoByCargoType[type] = dropOffableCargoByCargoType[type]
              + (((container.position - psPos):squaredLength() < 40*40) and add or 0)
          elseif cargo.destination.type == "facilityParkingspot" then
            dropOffableCargoByCargoType[cargo.type]  = dropOffableCargoByCargoType[type] + ((cargo.destination.psPath == elem.psPath and (container.position - psPos):squaredLength() < 40*40) and add or 0)
          elseif cargo.destination.type == "multi" then
            for _, dest in ipairs(cargo.destination.destinations) do
              dropOffableCargoByCargoType[type]  = dropOffableCargoByCargoType[type] + ((dest.psPath == elem.psPath and (container.position - psPos):squaredLength() < 40*40) and add or 0)
            end
          end
        end
      end
      local vehsClose, trailersClose = dVehicleTasks.canDropOffCargoAtPsPath(elem.psPath)
      local anyCargoDropOffable = (dropOffableCargoByCargoType.parcel > 0 or dropOffableCargoByCargoType.fluid > 0 or dropOffableCargoByCargoType.dryBulk > 0 or dropOffableCargoByCargoType.cement > 0 or dropOffableCargoByCargoType.cash > 0) or vehsClose > 0 or trailersClose > 0
      -- dropoff props
      if dropOffableCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = dropOffableCargoByCargoType.parcel > 1
            and core_locales.contextTranslate("ui.career.delivery.general.parcelsDropoff", {count = dropOffableCargoByCargoType.parcel})
            or _tr("ui.career.delivery.general.parcelDropoff")
        })
      end
      if dropOffableCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidDropoff", {volume = dropOffableCargoByCargoType.fluid})
        })
      end
      if dropOffableCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkDropoff", {volume = dropOffableCargoByCargoType.dryBulk})
        })
      end
      if dropOffableCargoByCargoType.cement > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL cement dropoff", dropOffableCargoByCargoType.cement)
        })
      end
      if dropOffableCargoByCargoType.cash > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%d cash dropoff", dropOffableCargoByCargoType.cash)
        })
      end
      if vehsClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.vehicleDropoff")
        })
      end
      if trailersClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.trailerDropoff")
        })
      end


      -- pickup data and props
      local pickUpAbleCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0,
        cement = 0,
        cash = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.transientCargo) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          if cargo.location.type == "facilityParkingspot" then
            pickUpAbleCargoByCargoType[cargo.type]  = pickUpAbleCargoByCargoType[type] + ((cargo.location.psPath == elem.psPath and (container.position - psPos):squaredLength() < 40*40) and add or 0)
          end
        end
      end
      local anyCargoPickUpAble = (pickUpAbleCargoByCargoType.parcel > 0 or pickUpAbleCargoByCargoType.fluid > 0 or pickUpAbleCargoByCargoType.dryBulk > 0 or pickUpAbleCargoByCargoType.cement > 0 or pickUpAbleCargoByCargoType.cash > 0)
      if pickUpAbleCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = pickUpAbleCargoByCargoType.parcel > 1
            and core_locales.contextTranslate("ui.career.delivery.general.parcelsPickup", {count = pickUpAbleCargoByCargoType.parcel})
            or _tr("ui.career.delivery.general.parcelPickup")
        })
      end
      if pickUpAbleCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidPickup", {volume = pickUpAbleCargoByCargoType.fluid})
        })
      end
      if pickUpAbleCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkPickup", {volume = pickUpAbleCargoByCargoType.dryBulk})
        })
      end    
      if pickUpAbleCargoByCargoType.cement > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL cement pickup", pickUpAbleCargoByCargoType.cement)
        })
      end
      if pickUpAbleCargoByCargoType.cash > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%d cash pickup", pickUpAbleCargoByCargoType.cash)
        })
      end


      if elem.canInspectCargo then
        -- available cargo data and props
        local availableCargoCountByCargoType = {
          parcel = 0,
          fluid = 0,
          dryBulk = 0,
          cement = 0,
          cash = 0,
        }
        for _, cargo in ipairs(dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(elem.facId)) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          availableCargoCountByCargoType[type] = availableCargoCountByCargoType[type] + add
        end
        -- Material availability is contract-based; raw facility stock is no
        -- longer freely loadable.
        for _, contract in ipairs(dMaterialContracts and dMaterialContracts.getOffersForFacility(elem.facId) or {}) do
          local template = dGenerator.getMaterialsTemplatesById(contract.materialType)
          if template then
            availableCargoCountByCargoType[template.type] = (availableCargoCountByCargoType[template.type] or 0) + contract.totalAmount
          end
        end
        for _, activeContract in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
          if activeContract.sourceFacId == elem.facId then
            local template = dGenerator.getMaterialsTemplatesById(activeContract.materialType)
            if template then
              availableCargoCountByCargoType[template.type] = (availableCargoCountByCargoType[template.type] or 0) + activeContract.loadableAmount
            end
          end
        end

        if availableCargoCountByCargoType.parcel > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(availableCargoCountByCargoType.parcel ~= 1 and "ui.career.delivery.general.parcelsAvailable" or "ui.career.delivery.general.parcelAvailable", {count = availableCargoCountByCargoType.parcel})
          })
        end
        if availableCargoCountByCargoType.fluid > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidAvailable", {volume = availableCargoCountByCargoType.fluid})
          })
        end
        if availableCargoCountByCargoType.dryBulk > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkAvailable", {volume = availableCargoCountByCargoType.dryBulk})
          })
        end
        if availableCargoCountByCargoType.cement > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%dL of cement available", availableCargoCountByCargoType.cement)
          })
        end
        if availableCargoCountByCargoType.cash > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%d cash available", availableCargoCountByCargoType.cash)
          })
        end
        -- veh and trailer props
        local vehOffers, trailerOffers = {}, {}
        for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(elem.facId)) do
          if offer.data.type == "vehicle" then
            table.insert(vehOffers, offer)
          end
          if offer.data.type == "trailer" then
            table.insert(trailerOffers, offer)
          end
        end
        if #vehOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(#vehOffers ~= 1 and "ui.career.delivery.general.vehicleTransportsAvailable" or "ui.career.delivery.general.vehicleTransportAvailable", {count = #vehOffers})
          })
        end
        if #trailerOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(#trailerOffers ~= 1 and "ui.career.delivery.general.trailerTransportsAvailable" or "ui.career.delivery.general.trailerTransportAvailable", {count = #trailerOffers})
          })
        end
      end

      -- make actual poi elemens

      for _, activeMaterialContract in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
        local isActiveMaterialPickup = activeMaterialContract.status == "active"
          and activeMaterialContract.origin and activeMaterialContract.origin.facId == elem.facId
          and activeMaterialContract.origin.psPath == elem.psPath and (activeMaterialContract.loadableAmount or 0) > 0

        if isActiveMaterialPickup then
        local materialPoi = deepcopy(poiTemplate)
        materialPoi.preheadings = {"Active Material Contract"}
        materialPoi.heading = string.format("Load %s", _tr(activeMaterialContract.materialName))
        materialPoi.props = {
          {icon = "locationSource", keyLabel = "Destination", valueLabel = _tr(activeMaterialContract.destinationName)},
          {icon = "checkmark", keyLabel = "Delivered", valueLabel = string.format("%d %s", math.floor((activeMaterialContract.deliveredAmount or 0) + 0.5), activeMaterialContract.units or "L")},
          {icon = "cargoBox", keyLabel = "In Transit", valueLabel = string.format("%d %s", math.floor((activeMaterialContract.inTransitAmount or 0) + 0.5), activeMaterialContract.units or "L")},
          {icon = "route", keyLabel = "Remaining", valueLabel = string.format("%d %s", math.floor((activeMaterialContract.remainingAmount or 0) + 0.5), activeMaterialContract.units or "L")},
        }
        materialPoi.buttonLabel = "Open Material Loader"
        local contractId = activeMaterialContract.id
        materialPoi.buttonFun = function()
          dCargoScreen.enterMaterialContractPickupScreen(contractId, elem.facId, elem.psPath)
        end
        table.insert(activityData, materialPoi)
        end
      end

      if anyCargoDropOffable then
        local dropOffPoi = deepcopy(poiTemplate)
        dropOffPoi.heading = _tr("ui.career.delivery.general.deliveryDropOff")
        dropOffPoi.buttonLabel = _tr("ui.career.delivery.general.dropOff")
        dropOffPoi.buttonFun = function() guihooks.trigger('ChangeState', {state = 'career.cargoDropOff', params = {facilityId = elem.facId, parkingSpotPath = elem.psPath}}) end
        dropOffPoi.icon = "poi_dropoff_round"
        table.insert(activityData, dropOffPoi)
      end

      if anyCargoPickUpAble then
        local pickUpPoi = deepcopy(poiTemplate)
        pickUpPoi.heading = _tr("ui.career.delivery.general.deliveryPickUp")
        pickUpPoi.buttonLabel = _tr("ui.career.delivery.general.pickUp")
        pickUpPoi.buttonFun = function()
          dParcelManager.applyTransientMoves({type="facilityParkingspot", facId = elem.facId, psPath = elem.psPath})
          M.requestUpdateContainerWeights()
          gameplay_markerInteraction.closeViewDetailPrompt(true)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
          gameplay_rawPois.clear()
          dCargoScreen.onCargoPickedUp()
        end
        pickUpPoi.icon = "poi_dropoff_round"
        table.insert(activityData, pickUpPoi)
      end
      if elem.canInspectCargo then
        local inspectPoi = poiTemplate
        inspectPoi.heading = _tr("ui.career.delivery.general.inspectCargo")
        inspectPoi.buttonLabel = _tr("ui.career.delivery.general.inspect")
        inspectPoi.buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId, elem.psPath) end
        table.insert(activityData, inspectPoi)
      end


    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData


local deliveryActivity = {
  id = "deliveryMode",
  name = _tr("ui.career.cargoOverview.deliveryMode"),

  vehicleModification = "warning",-- Slow and Fast Repairing, Changing and buying parts, tuning, painting
  vehicleSelling = "warning", --selling a vehicle
  vehicleStorage = "warning", --put vehicles into storage
  vehicleRepair = "warning",
  vehicleRetrieval = "allowed", --retrieve vehicles from storage

  vehicleShopping = "forbidden",

  interactRefuel = "allowed", --use the refueling POI to refuel vehicle
  interactMission = "warning", --use the mission POI to start a mission
  interactDelivery = "allowed", --use any delivery POI to start delivery mode

  recoveryFlipUpright = "allowed", --flip upright
  recoveryTowToRoad = "allowed", --tow to road
  recoveryTowToGarage = "warning", --tow to garage

  getLabel = function(tag)
    local penalty = -M.getDeliveryModePenalty().money
    local penaltyCtx = {penalty = string.format("%0.2f", penalty)}
    if     tag == "vehicleModification" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleModification", penaltyCtx)
    elseif tag == "vehicleSelling" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleSelling", penaltyCtx)
    elseif tag == "vehicleStorage" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleStorage", penaltyCtx)
    elseif tag == "vehicleRepair" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleRepair", penaltyCtx)
    elseif tag == "interactMission" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionInteractMission", penaltyCtx)
    elseif tag == "recoveryTowToGarage" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionRecoveryTowToGarage", penaltyCtx)
    elseif tag == "vehicleShopping" then
      return _tr("ui.career.delivery.general.permissionVehicleShopping")
    end
  end
}

local function onCheckPermission(tags, permissions)
  if not deliveryModeActive then return end
  for _, tag in ipairs(tags) do
    if deliveryActivity[tag] then
      table.insert(permissions, {permission = deliveryActivity[tag], label = deliveryActivity.getLabel(tag)})
      return
    end
  end
end

local function startDeliveryMode()
  if deliveryModeActive then return end
  log("I","","Delivery Mode Started.")
  deliveryModeActive = true
  gameplay_rawPois.clear()
  requestDeliveryPoiRefresh(true)
  extensions.hook("onDeliveryModeStarted")
end

local function exitDeliveryMode()
  if not deliveryModeActive then return end
  log("I","","Delivery Mode Exited.")
  -- clearTransientFlags is a deprecated stub that only emits an error. Clear
  -- the real pending-move list when leaving delivery mode instead.
  if dParcelManager.clearAllTransientMoves then
    dParcelManager.clearAllTransientMoves()
  end
  -- get all cargo currently in vehicles.
  local penalty = M.getDeliveryModePenalty()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  for _, cargo in ipairs(cargoInVehicles) do
    if cargo.location and cargo.location.vehId then
      M.rememberCargoWeightVehicle(cargo.location.vehId)
    end
  end
  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
    end
  end
  if penalty.money < 0 then
    fireCargoAbandonedNotification(penalty.money)
    log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
    career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  dVehicleTasks.abandonAllVehicleTasks()

  dParcelManager.clearAllTransientMoves()

  deliveryModeActive = false
  gameplay_rawPois.clear()
  freeroam_bigMapMode.setNavFocus(nil)

  M.requestUpdateContainerWeights()
  dTasklist.clearAll()
  if dMaterialContracts and dMaterialContracts.refreshTaskGuidance then
    dMaterialContracts.refreshTaskGuidance(true)
  end
  --core_gamestate.setGameState("career", "career")
  extensions.hook("onDeliveryModeStopped")
end

local function checkExitDeliveryMode()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  if not next(cargoInVehicles) and not next(vehicleTasks) then
    M.exitDeliveryMode()
  end
end

local function isAutomaticRouteEnabled()
  return loadData.settings.automaticRoute
end
M.isAutomaticRouteEnabled = isAutomaticRouteEnabled

local function setAutomaticRoute(enabled)
  loadData.settings.automaticRoute = enabled
  if enabled then
    career_modules_delivery_cargoScreen.setBestRoute()
  else
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
  end
  guihooks.trigger("automaticRouteSet", enabled)
end

local function setDetailedDropOff(enabled)
  loadData.settings.detailedDropOff = enabled
  guihooks.trigger("detailedDropOffSet", enabled)
end

-- Deactivate automatic route when setting a manual waypoint
local function onSetBigmapNavFocus()
  if M.isDeliveryModeActive() then
    setAutomaticRoute(false)
  end
end

local function setSetting(key, value)
  loadData.settings[key] = value
end

local function getSettings()
  return loadData.settings
end

M.setAutomaticRoute = setAutomaticRoute
M.setDetailedDropOff = setDetailedDropOff
M.onSetBigmapNavFocus = onSetBigmapNavFocus

M.setSetting = setSetting
M.getSettings = getSettings

M.startDeliveryMode = startDeliveryMode
M.exitDeliveryMode = exitDeliveryMode
M.checkExitDeliveryMode = checkExitDeliveryMode
M.isDeliveryModeActive = function() return deliveryModeActive end

M.getDeliveryModePenalty = function(onlyVehIdsAsKeys)
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local penalty = {money = 0}
  if not onlyVehIdsAsKeys then
    local fine = dVehicleTasks.getFineForAbandonAllVehicleTasks()
    for attKey, amount in pairs(fine) do
      penalty[attKey] = (penalty[attKey] or 0) + amount
    end
  end

  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      if (not onlyVehIdsAsKeys) or (cargo.location.vehId and onlyVehIdsAsKeys[cargo.location.vehId]) then
        local abandonFac = M.getDeliveryAbandonPenaltyFactor()
        local modFac = 0
        if cargo.modifiers then
          for _, mod in ipairs(cargo.modifiers) do
            modFac = modFac + (mod.abandonMultiplier or 0)
          end
        end
        if not cargo._transientMove then
          penalty.money = penalty.money - cargo.rewards.money * (abandonFac + modFac)
        end
        if cargo.organization and penalty[cargo.organization.."Reputation"] then
          penalty[cargo.organization.."Reputation"] = penalty[cargo.organization.."Reputation"] or 0
          penalty[cargo.organization.."Reputation"] = penalty[cargo.organization.."Reputation"] - math.ceil(cargo.rewards[cargo.organization.."Reputation"] or 0)
        end
      end
    end
  end
  return penalty
end

M.onCheckPermission = onCheckPermission

-- actions that stop delivery mode

M.onPartShoppingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because shopping started.")
    M.exitDeliveryMode()
  end
end

M.onCareerPaintingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because painting started.")
    M.exitDeliveryMode()
  end
end

M.onCareerTuningStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because tuning started.")
    M.exitDeliveryMode()
  end
end

M.onTeleportedToGarage = function(garageId, veh)
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because towed to garage.")
    M.exitDeliveryMode()
  end
end

M.onAnyMissionChanged = function(change)
  if change == "started" then
    if deliveryModeActive then
      log("I","","Stopped Delivery mode because mission started.")
      M.exitDeliveryMode()
    end
  end
end

local function checkEndDeliveryModeForVehicle(vehId)
  if deliveryModeActive then
    -- TODO: this needs to check for cargo in vehicle containers, not just vehicle
    local penalty = M.getDeliveryModePenalty({[vehId] = true})
    local cargoInVehicle = dParcelManager.getAllCargoCustomFilter(function(cargo)
      if cargo.location.type == "vehicle" and cargo.location.vehId == vehId then
        return true
      end
      if cargo._transientMove and cargo.transientMove.targetLocation.vehId == vehId then
        return true
      end
    end)
    if next(cargoInVehicle) then
      for _, cargo in ipairs(cargoInVehicle) do
        dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
      end
      if penalty.money < 0 then
        fireCargoAbandonedNotification(penalty.money)
        log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
        career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
      end
    end
    checkExitDeliveryMode()
  end
end

M.onRepairInGarage = function(invVehId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(invVehId)
  checkEndDeliveryModeForVehicle(vehId)
end

M.onInventoryPreRemoveVehicleObject = function(inventoryId, vehId)
  checkEndDeliveryModeForVehicle(vehId)
end



return M
