-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local sharedCalc = require('gameplay/delivery/calculators')

M.dependencies = {"core_vehicleBridge"}

local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehOfferManager, dParcelMods, dVehicleTasks, dTutorial, dMaterialContracts
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dParcelMods = career_modules_delivery_parcelMods
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTutorial = career_modules_delivery_tutorial
  dMaterialContracts = career_modules_delivery_materialContractManager
  step = util_stepHandler
end

local cardsById = {}
local cardId = 0

local function addCard(data)
  --data.cardId = cardId
  --cardId = cardId + 1
  local id = data.isFacilityCard and "F-" or "P-"
  if data.cardType == "parcelGroup" then
    id = id .. "pg-"..data.id
  elseif data.cardType == "storage" then
    id = id .. "st-"..data.id
  elseif data.cardType == "materialContractOffer" then
    id = id .. "mc-"..data.id
  elseif data.cardType == 'vehicleOffer' then
    id = id .. "vo-"..data.id
  elseif data.cardType == "loaner" then
    id = id .."lo-"..data.id
  end
  data.cardId = id
  cardsById[data.cardId] = data
end
local cargoOverviewScreenOpen = false
local cargoOverviewTab = ""
local cargoDataRequestSerial = 0
local cargoOverviewUiReady = false
local cargoOverviewEnterToken = 0
local CARGO_OVERVIEW_UI_READY_TIMEOUT = 5
local visibleBigMapIdsToCardIds = {}
local vehicleSpawnInProgress = false
local pendingTransientMoves = false
local materialPickupScreenOpen = false
local materialPickupFacId, materialPickupPsPath, materialPickupContractId = nil, nil, nil
local materialPickupLoadInProgress = false
M.isCargoScreenOpen = function() return cargoOverviewScreenOpen end
M.setCargoScreenTab = function(tab)
    --print("cargo tab -> " .. dumps(tab))
    cargoOverviewTab = tab
    --M.setVisibleIdsForBigMap()
    local visibleIds = {}
    local idx = 1
    for bmId, data in pairs(visibleBigMapIdsToCardIds) do
      for cardId, _ in pairs(data.cardIds) do
        local card = cardsById[cardId]
        if card.filterTags[tab] or card.filterTags['myCargo'] then
          visibleIds[idx] = bmId
          idx = idx + 1
          goto continue
        end
      end

      ::continue::
    end
    freeroam_bigMapMode.setOnlyIdsVisible(visibleIds)
    gameplay_rawPois.clear()
    freeroam_bigMapMarkers.clearMarkers()
    freeroam_bigMapMarkers.setNextMarkersFullAlphaInstant()
end
M.getCargoScreenTab = function() return cargoOverviewTab end
local cargoScreenFacId, cargoScreenPsPath = nil, nil
M.getCargoScreenLocation = function()
  if not cargoOverviewScreenOpen or not cargoScreenFacId then return nil end
  return {facId = cargoScreenFacId, psPath = cargoScreenPsPath}
end
local cargoOverviewScreenOpenedTime = -1
local cargoOverviewMaxTimeTimestamp = -1
local sentNewCargoNotificationAlready = false
-- how far back in time items should be shown
local pastDeliveryTimespan = 0

--temp table for calculations
local vehToLocationDistanceCache = {}

----------------------
-- Cargo Formatting --
----------------------

-- helper functions
local lowestIdSort = function(a,b) return a.ids[1] < b.ids[1] end
local idSort = function(a,b) return a.id < b.id end

-- formats a group of "identical" cargo (ie same name, destination, etc)
local function formatCargoGroup(group, playerCargoContainers, showFirstSeen)
  table.sort(group, idSort)
  local material = group[1].materialType and dGenerator.getMaterialsTemplatesById(group[1].materialType) or nil
  local ret = {
    id = group[1].id,

    ids = {}, -- implicit count of included objects in this group

    name = _tr(group[1].name),
    loadedAtTimeStamp = group[1].loadedAtTimeStamp,

    originName = dParcelManager.getLocationLabelShort(group[1].origin),
    locationName = dParcelManager.getLocationLabelShort(group[1].location),
    destinationName = dParcelManager.getLocationLabelShort(group[1].destination),

    originNameLong = dParcelManager.getLocationLabelLong(group[1].origin),
    locationNameLong = dParcelManager.getLocationLabelLong(group[1].location),
    destinationNameLong = dParcelManager.getLocationLabelLong(group[1].destination),

    origin = group[1].origin,
    location = group[1].location,
    destination = group[1].destination,

    type = group[1].type,
    materialType = group[1].materialType,
    materialContractId = group[1].data and group[1].data.materialContractId or nil,
    slots = group[1].slots,
    distance = group[1].data.originalDistance,
    rewardMoney = group[1].rewards.money,
    economyMultiplier = (group[1].rewards and group[1].rewards.economyMultiplier) or 1,
    weight = group[1].weight,
    units = material and (material.units or "L") or nil,
    rewardMoneyPerKg = material and sharedCalc.getMaterialMoneyPerKg(material) or nil,

    enabled = true, -- not needed in player view
    disableReason = {}, -- not needed in player view

    targetLocations = {},
    autoLoadLocations = {},
    remainingOfferTime = group[1].offerExpiresAt - dGeneral.time(),

    modifiers = {},

    automaticDropOff = group[1].automaticDropOff,
    _transientMove = group[1]._transientMove,
    hiddenInFacility = group[1].hiddenInFacility,

    route = {
      type = "navgraph",
      locations = {group[1].location, group[1].destination}
    },
    bigMapIds = {}

  }
  if group[1].destination.type ~= "multi" then
    ret.bigMapIds[string.format("delivery-parking-%s-%s", group[1].destination.facId, group[1].destination.psPath)] = true
  else
    for _, loc in ipairs(group[1].destination.destinations) do
      ret.bigMapIds[string.format("delivery-parking-%s-%s", loc.facId, loc.psPath)] = true
    end
  end

  if group[1]._transientMove then
    ret.bigMapIds = {}
    ret.bigMapIds[string.format("delivery-parking-%s-%s", group[1].location.facId, group[1].location.psPath)] = true
  end


  -- add all ids to the ret.
  for _, cargo in ipairs(group) do
    table.insert(ret.ids, cargo.id)
  end

  -- check if any cargo in the group is already reserved for movement.
  local transientMoveCounts = 0
  for _, cargo in ipairs(group) do
    transientMoveCounts = transientMoveCounts + (cargo._transientMove and 1 or 0)
  end
  ret.transientMoveCounts = transientMoveCounts

  -- update fields for "first seen" items
  if showFirstSeen then
    if group[1].firstSeen and (dGeneral.time() - group[1].firstSeen) < 3 then
      ret.showNewTimer = 3 - (dGeneral.time() - group[1].firstSeen)
    end
  end

  -- modifiers
  local modifierKeys = {}
  for _, mod in ipairs(group[1].modifiers) do
    local modData = dParcelMods.getModData(mod.type)
    modifierKeys[mod.type] = true
    if not modData.hidden then
      local modProp = {type = mod.type, icon = modData.icon, active = true, label = modData.label, description = modData.shortDescription, important = modData.important}
      table.insert(ret.modifiers, modProp)
      if mod.type == "timed" then
        ret.hasTimerMod = true
        ret.remainingTime = {}
        if ret.loadedAtTimeStamp then
          local expiredTime = dGeneral.time() - ret.loadedAtTimeStamp
          if expiredTime <= mod.timeUntilDelayed then
            ret.remainingTime = {
              type = "untilDelayed",
              time = mod.timeUntilDelayed - expiredTime,
              percent = (mod.timeUntilDelayed - expiredTime) / mod.timeUntilDelayed

            }
          elseif expiredTime <= mod.timeUntilLate then
            ret.remainingTime = {
              type = "untilLate",
              time = mod.timeUntilLate - expiredTime,
              percent = (mod.timeUntilLate - expiredTime) / (mod.timeUntilLate-mod.timeUntilDelayed)
            }
          else
            ret.remainingTime = {
              type = "late",
              percent = 0
            }
          end
        else
          ret.remainingTime = {
            type = "preLoad",
            time = mod.timeUntilDelayed,
          }
        end
      end
    end
  end


  -- if the item has the timed modifier, adjust remaining time
  --[[
  -- TODO: add warning for timed mods if late
  if modifierKeys.timed then
    -- bonus time for timed cargo is in the modifier.
    for _, mod in ipairs(ret.modifiers) do
      if mod.key == "timed" then
        if ret.loadedAtTimeStamp > (mod.bonusTime * -1) then
          ret.remainingOfferTime = ret.remainingOfferTime + mod.bonusTime
          mod.warning = true
        end
      end
    end
  end]]

  if not playerCargoContainers then
    return ret
  end

  -- if this item is expired, return early.
  if ret.remainingOfferTime <= 0 then
    ret.enabled = false
    ret.disableReason = {type = "expired"}
    return ret
  end

  -- if tutorial is active and this is not a tutorial parcel, disable it
  local isCargoDeliveryTutorialActive = dTutorial.isCargoDeliveryTutorialActive()
  if isCargoDeliveryTutorialActive then
    local template = dGenerator.getParcelTemplateById(group[1].templateId)
    if template and not template.isTutorialParcel then
      ret.enabled = false
      ret.disableReason = {type = "tutorial", label = _tr("ui.career.delivery.cargoScreen.disabledDuringTutorial")}
      return ret
    end
  end

  -- if this item is locked because of progress, disable it.
  local lockedBecauseOfMods, flagDefinition = dParcelMods.lockedBecauseOfMods(modifierKeys)
  if flagDefinition then
    ret.unlockInfo = flagDefinition.unlockInfo
  end
  if lockedBecauseOfMods then
    ret.enabled = false
    ret.disableReason = flagDefinition and flagDefinition.lockedReason
    return ret
  end

  -- calculate "possible targets" for moving this cargo group, based on player cargo containers
  local cargo = group[1]
  for _, con in ipairs(playerCargoContainers) do
    -- if this container has other cargo that does not match with the current cargo, skip container.
    if next(con.rawCargo) and cargo.type then
      local isMixable = dGenerator.isMixable(cargo.type)
      if not isMixable then
        for _, otherCargo in ipairs(con.rawCargo) do
          if otherCargo.type ~= cargo.type then
            goto continue
          end
        end
      end
    end
    -- figure out how many of these can go in at once
    if not con.cargoTypesLookup[group[1].type] then
      goto continue
    end

    local maxAmount = math.floor(con.freeCargoSlots / group[1].slots)
    if maxAmount > 0 then
      local elem = {
        enabled = con.freeCargoSlots >= group[1].slots,
        label = con.moveToLabel,
        location = con.location,
        maxAmount = maxAmount,
        selectedAmount = 0,
        containerVehicleInfo = {
          vehId = con.vehId,
          vehName = con.vehName,
          conName = con.name,
        },
        usedCargoSlots = con.usedCargoSlots,
        totalCargoSlots = con.totalCargoSlots,
      }

      -- check how many cargo in this group are already supposed to be going there
      for _, cargo in ipairs(group) do
        if cargo._transientMove then
          if dParcelManager.sameLocation(cargo._transientMove.targetLocation, con.location) then
            elem.maxAmount = elem.maxAmount + 1
            elem.selectedAmount = elem.selectedAmount + 1
            elem.usedCargoSlots = elem.usedCargoSlots - cargo.slots
            elem.enabled = true
          end
        end
      end

      table.insert(ret.targetLocations, elem)
    end

    ::continue::
  end

  -- if there is no target, that means there is "no space"
  if not next(ret.targetLocations) and transientMoveCounts == 0 then
    ret.enabled = false
    ret.disableReason = {type = "noSpace"}
    return ret
  end


  -- figure out where the cargo will go when auto loading
  local tgtIds = {}
  for id, elem in ipairs(ret.targetLocations) do
    if elem.enabled then
      table.insert(tgtIds, id)
    end
  end
  table.sort(tgtIds, function(a,b)
      local tgtA = ret.targetLocations[a]
      local tgtB = ret.targetLocations[b]
      if tgtA.maxAmount ~= tgtB.maxAmount then
        return tgtA.maxAmount > tgtB.maxAmount
      else
        return (tgtA.totalCargoSlots - tgtA.usedCargoSlots) < (tgtB.totalCargoSlots - tgtB.usedCargoSlots)
      end
    end
    )
  ret.autoLoadLocations = {}
  local autoloadCounts = 0
  for _, id in ipairs(tgtIds) do
    for i = 1, ret.targetLocations[id].maxAmount do
      if autoloadCounts < #ret.ids then
        table.insert(ret.autoLoadLocations, ret.targetLocations[id].location)
        autoloadCounts = autoloadCounts + 1
      end
    end
  end

  if not next(ret.autoLoadLocations) and ret.transientMoveCounts == 0 then
    ret.enabled = false
    ret.disableReason = {type = "noSpace"}
    return ret
  end

  return ret
end
M.formatCargoGroup = formatCargoGroup


M.tryLoadAll = function(ids)



end


-- this function first groups the cargo, then formats each individual group.
local function clusterFormatCargo(cargo, playerCargoContainers, updateFirstSeen)
  local ret = {}
  --cargo can only be clustered if their groupId is the same
  --current location also needs to be the same, but that is guaranteed by the caller of this function
  local cargoByGroupId = {}
  for _, c in ipairs(cargo) do
    --if not c.hiddenInFacility then
      local gId = string.format("%d-%d", c.groupId, c.loadedAtTimeStamp or -1)
      cargoByGroupId[gId] = cargoByGroupId[gId] or {}
      -- finalize the fields that require "costly" computation at this point
      dGenerator.finalizeParcelItemDistanceAndRewards(c)
      if updateFirstSeen then
        c.firstSeen = c.firstSeen or dGeneral.time()
      end
      table.insert(cargoByGroupId[gId], c)
    --end
  end
  -- format each group individually
  for _, group in pairs(cargoByGroupId) do
    local formatted = formatCargoGroup(group, playerCargoContainers, updateFirstSeen)
    table.insert(ret, formatted)
    formatted.cardType = "parcelGroup"
    if playerCargoContainers then
      formatted.isFacilityCard = true
    else
      formatted.isPlayerCard = true
    end
    addCard(formatted)
  end
  table.sort(ret, lowestIdSort)
  return ret
end

------------------------------
-- Vehicle Offer Formatting --
------------------------------

-- gets the thumbnail for a vehicle
local function getVehicleThumb(vehicle)
  local model = core_vehicles.getModel(vehicle.model)
  if not model or not model.configs or not vehicle.config then return nil end
  local config = model.configs[vehicle.config]
  if not config then return nil end
  return config.preview
end



local function formatVehicleOfferForUi(offers)
  local ret = {}

  local isVehicleDeliveryTutorialActive = dTutorial.isVehicleDeliveryTutorialActive()

  for _, offer in ipairs(offers) do
    dGenerator.finalizeVehicleOffer(offer)
    local item = {
      id = offer.id,
      name = offer.vehicle.name,
      type = "vehOffer",
      vehOfferType = offer.data.type,
      vehName = offer.vehicle.name,
      vehBrand = offer.vehicle.brand,
      vehMileage = offer.vehicle.mileage,
      destinationName = dParcelManager.getLocationLabelShort(offer.task.destination),
      destinationNameLong = dParcelManager.getLocationLabelLong(offer.task.destination),
      locationName = dParcelManager.getLocationLabelShort(offer.origin),
      locationNameLong = dParcelManager.getLocationLabelLong(offer.origin),
      task = dVehOfferManager.makeTaskLabel(offer.task),
      thumbnail = getVehicleThumb(offer.vehicle) or '/ui/images/appDefault.png',
      distance = offer.data.originalDistance,
      rewards = offer.rewards,
      rewardMoney = offer.rewards.money,
      economyMultiplier = (offer.rewards and offer.rewards.economyMultiplier) or 1,
      remainingOfferTime = offer.offerExpiresAt - (dGeneral.time()),
      connector = "ConName",
      unlockTag = offer.vehicle.filterName,
      enabled = true,
      spawnWhenCommitingCargo = offer.spawnWhenCommitingCargo,

      route = {
        type = "navgraph",
        locations = {offer.origin, offer.task.destination}
      },
      modifiers = dVehOfferManager.getDefaultVehicleModifiersForUI(),
      bigMapIds = {}
    }

    local enabled, flagDefinition = dVehOfferManager.isVehicleTagUnlocked(offer.vehicle.unlockTag)
    local isCargoDeliveryTutorialActive = dTutorial.isCargoDeliveryTutorialActive()
    item.bigMapIds[string.format("delivery-parking-%s-%s", offer.task.destination.facId, offer.task.destination.psPath)] = true

    -- if this item is expired, return early.
    if item.remainingOfferTime <= 0 then
      item.enabled = false
      item.disableReason = {type = "expired"}
      goto continue
    end

    -- if tutorial is active, only allow tutorial vehicles
    if isCargoDeliveryTutorialActive then
      if not (offer.data and offer.data.isTutorialVehicle) then
        item.enabled = false
        item.disableReason = {type = "tutorial", label = _tr("ui.career.delivery.cargoScreen.disabledDuringTutorial")}
        goto continue
      end
    end

    -- if vehicle delivery tutorial is active, only allow tutorial vehicles
    if isVehicleDeliveryTutorialActive then
      if not (offer.data and offer.data.isTutorialVehicle) then
        item.enabled = false
        item.disableReason = {type = "tutorial", label = _tr("ui.career.delivery.cargoScreen.disabledDuringTutorial")}
        goto continue
      end
    end

    item.unlockInfo = flagDefinition and flagDefinition.unlockInfo
    if not enabled then
      item.enabled = false
      item.disableReason = flagDefinition and flagDefinition.lockedReason
      goto continue
    end

    ::continue::

    if item.spawnWhenCommitingCargo then
      item.enabled = true
      item.disableReason = nil
    end


    table.insert(ret, item)
    item.cardType = "vehicleOffer"
    item.isFacilityCard = true
    addCard(item)
  end
  return ret
end


local function formatAcceptedOfferForUI(offer)
  local item = {
    id = offer.id,
    name = offer.vehicle.name,
    vehName = offer.vehicle.name,
    vehBrand = offer.vehicle.brand,
    vehMileage = offer.vehicle.mileage,
    vehOfferType = offer.data.type,
    destinationName = dParcelManager.getLocationLabelShort(offer.task.destination),
    task = dVehOfferManager.makeTaskLabel(offer.task),
    thumbnail = getVehicleThumb(offer.vehicle) or '/ui/images/appDefault.png',
    distance = offer.data.originalDistance,
    rewards = offer.rewards,
    rewardMoney = offer.rewards.money,
    economyMultiplier = (offer.rewards and offer.rewards.economyMultiplier) or 1,
    connector = "ConName",
    type = offer.data.type,
    enabled = true,


    route = {
      type = "navgraph",
      locations = {{type="vehicle", vehId = offer.vehicle.vehId}, offer.task.destination}
    },
    modifiers = dVehOfferManager.getDefaultVehicleModifiersForUI(),
    bigMapIds = {}
  }
  item.bigMapIds[string.format("delivery-parking-%s-%s", offer.task.destination.facId, offer.task.destination.psPath)] = true

  if offer.vehicle then
    item.abandonInfo = {
      penaltyMoney = offer.rewards.money * dGeneral.getDeliveryAbandonPenaltyFactor(),
      vehId = offer.vehicle.vehId
    }
  end

  item.taskList = {_tr("ui.career.delivery.cargoScreen.noTask")}
  local task = dVehicleTasks.getVehicleTaskForOffer(offer)
  if not task or not task.tasks then
    if item.type == "vehicle" then
      item.taskList = {_tr("ui.career.delivery.cargoScreen.enterVehicle")}
    else
      item.taskList = {_tr("ui.career.delivery.cargoScreen.coupleTrailer")}
    end
  else
    local task = task.tasks[task.activeTaskIndex]
    item.taskList = {task.type or "no type?"}
    if task.type == "coupleTrailer" then
      item.taskList = {_tr("ui.career.delivery.cargoScreen.coupleTrailer")}
    elseif task.type == "enterVehicle" then
      item.taskList = {_tr("ui.career.delivery.cargoScreen.enterVehicle")}
    elseif task.type == "bringToDestination" or task.type == "confirmDropOff" then
      item.taskList = {item.type == "trailer"
        and core_locales.contextTranslate("ui.career.delivery.cargoScreen.dropOffTrailer", {destination = item.destinationName})
        or core_locales.contextTranslate("ui.career.delivery.cargoScreen.dropOffVehicle", {destination = item.destinationName})}
    elseif task.type == "putIntoParkingSpot" then
      --not used atm
    end
  end
  return item
end
M.formatAcceptedOfferForUI = formatAcceptedOfferForUI
M.abandonAcceptedOffer = function(vehId)
  dVehicleTasks.giveBackDeliveryVehicle(vehId)
end

local function getAcceptedVehicleOffers()
  local vehicleTasks = career_modules_delivery_vehicleTasks.getVehicleTasks()
  local res = {}
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.giveBack then
      local vehOffer = formatAcceptedOfferForUI(taskData.offer)
      table.insert(res, vehOffer)
      vehOffer.cardType = "vehicleOffer"
      vehOffer.isPlayerCard = true
      addCard(vehOffer)
    end
  end


  local vehOffers = dVehOfferManager.getAllOfferUnexpired()
  for _, offer in ipairs(vehOffers) do
    if offer.spawnWhenCommitingCargo then
      local vehOffer = formatAcceptedOfferForUI(offer)
      vehOffer.transientMove = true
      table.insert(res, vehOffer)
      vehOffer.cardType = "vehicleOffer"
      vehOffer.isPlayerCard = true
      vehOffer.spawnWhenCommitingCargo = true
      addCard(vehOffer)
    end
  end

  return res
end

---------------------------
-- Material Data Formatting --
---------------------------

local function formatLoadTargets(storage, playerCargoContainers)
  local targetLocations = {}
  local totalStorableVolume = 0
  if not storage or not storage.materialType then
    return targetLocations
  end
  for _, con in ipairs(playerCargoContainers) do
    local materialData = dGenerator.getMaterialsTemplatesById(storage.materialType)
    if not materialData then
      goto continue
    end
    local materialDataType = materialData.type

    if con.cargoTypesLookup[materialDataType] then
      totalStorableVolume = totalStorableVolume + con.freeCargoSlots

      local transientCargoSlots = 0
      if storage.id then
        for _, cargo in ipairs(dParcelManager.getAllCargoCustomFilter(function(c) return c.sourceStorage == storage.id and c._transientMove end)) do
          if dParcelManager.sameLocation(cargo._transientMove.targetLocation, con.location) then
            transientCargoSlots = transientCargoSlots + cargo.slots
          end
        end
      end

      if storage.storedVolume > 0 then

        -- use empty containers or same-fluids containers with remaining space
        if con.usedCargoSlots-transientCargoSlots == 0 then
          table.insert(targetLocations, {
            label = con.name,
            maxAmount = math.min(con.freeCargoSlots+transientCargoSlots, storage.storedVolume),
            selectedAmount = transientCargoSlots,
            location = con.location,
            containerVehicleInfo = {
              vehId = con.vehId,
              vehName = con.vehName,
              conName = con.name,
            },
            usedCargoSlots = 0,
            totalCargoSlots = con.totalCargoSlots,

          })
        end
        if (con.freeCargoSlots+transientCargoSlots) > 0 and next(con.rawCargo) and con.rawCargo[1].materialType == storage.materialType then
          table.insert(targetLocations, {
            label = con.name,
            maxAmount = math.min(con.freeCargoSlots+transientCargoSlots, storage.storedVolume),
            selectedAmount = transientCargoSlots,
            location = con.location,
            containerVehicleInfo = {
              vehId = con.vehId,
              vehName = con.vehName,
              conName = con.name,
            },
            usedCargoSlots = con.usedCargoSlots - transientCargoSlots,
            totalCargoSlots = con.totalCargoSlots,
          })
        end
      end
    end
    ::continue::
  end
  --[[
  if totalStorableVolume == 0 then
    table.insert(targetLocations, {
      label = "No Space!",
      amount = math.min(totalStorableVolume, storage.storedVolume),
      disabled = true,
    })
  end
  if storage.storedVolume == 0 then
    table.insert(targetLocations, {
      label = "Nothing to load!",
      amount = math.min(totalStorableVolume, storage.storedVolume),
      disabled = true,
    })
  end
  if totalStorableVolume > 0 and storage.storedVolume > 0 then
    table.insert(targetLocations, {
      label = "Load All",
      amount = math.min(totalStorableVolume, storage.storedVolume),
      targetLocation = {type="auto"}
    })
  end
  ]]
  return targetLocations
end

local function clearTransientMovesForStorage(materialType)
  local fac = dGenerator.getFacilityById(cargoScreenFacId)
  local facStorage = fac.materialStorages and fac.materialStorages[materialType]
  if not facStorage or not facStorage.id then
    return
  end
  for _, cargo in ipairs(dParcelManager.getAllCargoCustomFilter(function(c) return c.sourceStorage == facStorage.id and c._transientMove end)) do
    dParcelManager.clearTransientMoveForCargo(cargo.id)
    dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
  end
end
M.clearTransientMovesForStorage = clearTransientMovesForStorage

local function moveMaterialFromUi(materialType, cargoType, amount, targetLocation, contractId)
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)

    --dump(materialType, cargoType, amount, targetLocation)

    local fac = dGenerator.getFacilityById(cargoScreenFacId)
    local facStorage = fac.materialStorages and fac.materialStorages[materialType]
    local materialData = dGenerator.getMaterialsTemplatesById(materialType)
    local contract = dMaterialContracts and dMaterialContracts.getContractById(contractId)
    if not facStorage or not facStorage.id or not materialData or not contract
      or contract.status ~= "active" or contract.sourceFacId ~= cargoScreenFacId or contract.materialType ~= materialType
      or not contract.origin or contract.origin.psPath ~= cargoScreenPsPath then
      guihooks.trigger("requestCargoDataSimple")
      return
    end
    amount = math.min(math.max(0, tonumber(amount) or 0), contract.loadableAmount or 0)

    local allValidStorages = {}
    if targetLocation.type == "auto" then
      -- figure out eligible storages from the player where it can go into
      local emptyPartialStorages, emptyWholeStorages, validPartialStorages, validWholeStorages = {}, {}, {}, {}
      for _, con in ipairs(playerCargoContainers) do
        if con.cargoTypesLookup[cargoType] and con.freeCargoSlots > 0 then
          if not next(con.rawCargo) then
            if con.freeCargoSlots < amount then
              table.insert(emptyPartialStorages, con)
            else
              table.insert(emptyWholeStorages, con)
            end
          else
            if con.rawCargo[1].materialType == materialType then
              if con.freeCargoSlots < amount then
                table.insert(validPartialStorages, con)
              else
                table.insert(validWholeStorages, con)
              end
            end
          end
        end
      end

      -- sort whole storages by remaining(total) volume - smallest first
      table.sort(emptyWholeStorages, function(a,b) return a.freeCargoSlots < b.freeCargoSlots end)
      table.sort(validWholeStorages, function(a,b) return a.freeCargoSlots < b.freeCargoSlots end)

      -- sort partial storages by remaining volume - largest first
      table.sort(emptyPartialStorages, function(a,b) return a.freeCargoSlots < b.freeCargoSlots end)
      table.sort(validPartialStorages, function(a,b) return a.freeCargoSlots < b.freeCargoSlots end)

      -- all of these storages should be able to take at least some of the material
      arrayConcat(allValidStorages, validWholeStorages)
      arrayConcat(allValidStorages, validPartialStorages)
      arrayConcat(allValidStorages, emptyWholeStorages)
      arrayConcat(allValidStorages, emptyPartialStorages)
    elseif targetLocation.type == "vehicle" then
      for _, con in ipairs(playerCargoContainers) do
        if con.containerId == targetLocation.containerId and con.vehId == targetLocation.vehId then
          table.insert(allValidStorages, con)
        end
      end
    end
    -- fill in storages one after another until we're done or out of storages (out of storages should be checked before sending to the UI anyway...)
    local remainingVolume = amount
    local storageIdx = 1
    while remainingVolume > 0 and storageIdx <= #allValidStorages do
      local storage = allValidStorages[storageIdx]
      local storageAmount = math.min(storage.freeCargoSlots, remainingVolume)
      if storageAmount > 0 then
        -- this removes the facility tank too
        dGenerator.addMaterialAsParcelToContainer(storage, facStorage, storageAmount, cargoScreenFacId, cargoScreenPsPath, contract.id)
      end
      remainingVolume = remainingVolume - storageAmount
      storageIdx = storageIdx + 1
    end
    if remainingVolume > 0 then
      log("W","",string.format("Tried loading %0.1fL %s from %s, but %0.1fL remained unloaded!",amount, materialType, fac.id, remainingVolume))
    end
    -- finally notify the UI that this action is done
    guihooks.trigger("requestCargoDataSimple")
  end)
end
M.moveMaterialFromUi = moveMaterialFromUi


local function formatMaterialStorage(fac, facPsLocation, playerCargoContainers)
  table.sort(playerCargoContainers, function(a,b) return a.freeCargoSlots < b.freeCargoSlots end)
  local data = { }
  if not dMaterialContracts then return data end
  local activeContracts = dMaterialContracts.getActiveContracts()
  local tutorialActive = dTutorial.isCargoDeliveryTutorialActive()

  local function compatibleCapacity(material)
    local capacity = 0
    for _, con in ipairs(playerCargoContainers or {}) do
      if con.cargoTypesLookup and con.cargoTypesLookup[material.type] then
        capacity = capacity + math.max(0, con.totalCargoSlots or con.freeCargoSlots or 0)
      end
    end
    return capacity
  end

  for _, offer in ipairs(dMaterialContracts.getOffersForFacility(fac.id)) do
    local material = dGenerator.getMaterialsTemplatesById(offer.materialType)
    if material then
    local locked, flagDefinition = dParcelMods.lockedBecauseOfMods({[material.type]=true})
      local equipmentCapacity = compatibleCapacity(material)
      local offerData = {
        id = offer.id,
        materialContractId = offer.id,
        cardType = "materialContractOffer",
        isFacilityCard = true,
        name = _tr(offer.materialName),
        materialType = offer.materialType,
        material = material,
        destinationName = _tr(offer.destinationName),
        destinationNameLong = _tr(offer.destinationName),
        distance = offer.routeDistance,
        slots = offer.totalAmount,
        units = offer.units or material.units or "L",
        standardLoad = offer.standardLoad,
        standardLoadCount = offer.loadCount,
        estimatedTrips = equipmentCapacity > 0 and math.ceil(offer.totalAmount / equipmentCapacity) or 0,
        estimatedStandardLoadPay = (offer.quotedRewards.money or 0) / math.max(1, offer.loadCount),
        rewardMoney = offer.quotedRewards.money or 0,
        quotedRewards = offer.quotedRewards,
        abandonmentRate = 0.15,
        remainingTime = {type = "offer", time = math.max(0, offer.offerExpiresAt - dGeneral.time())},
        modifiers = {},
        enabled = not locked and not tutorialActive,
        unlockInfo = flagDefinition and flagDefinition.unlockInfo,
        bigMapIds = {},
      }
      local label, desc = dParcelMods.getLabelAndShortDescription(material.type)
      table.insert(offerData.modifiers, {type = material.type, icon = dParcelMods.getModifierIcon(material.type), active = true, label = label, description = desc})
      if locked then offerData.disableReason = flagDefinition.lockedReason
      elseif tutorialActive then offerData.disableReason = {type = "tutorial", label = _tr("ui.career.delivery.cargoScreen.disabledDuringTutorial")} end
      table.insert(data, offerData)
      addCard(offerData)
    end
  end

  for _, active in ipairs(activeContracts) do
  if active.sourceFacId == fac.id and active.status == "active" then
    local material = dGenerator.getMaterialsTemplatesById(active.materialType)
    local sourceStorage = fac.materialStorages and fac.materialStorages[active.materialType]
    if material and sourceStorage then
      local virtualStorage = deepcopy(sourceStorage)
      virtualStorage.storedVolume = active.sourceReservedAmount
      virtualStorage.capacity = active.totalAmount
      local atContractPickup = active.origin and active.origin.psPath == cargoScreenPsPath
      local pickupName = string.format("%s loading point", _tr(active.sourceName))
      local activeData = {
        id = active.id,
        storageId = sourceStorage.id,
        materialContractId = active.id,
        materialContractActive = true,
        sourceFacId = active.sourceFacId,
        origin = deepcopy(active.origin),
        cardType = "storage",
        isFacilityCard = true,
        name = _tr(active.materialName),
        materialType = active.materialType,
        material = material,
        storage = virtualStorage,
        targetLocations = atContractPickup and formatLoadTargets(virtualStorage, playerCargoContainers) or {},
        destinationName = _tr(active.destinationName),
        destinationNameLong = _tr(active.destinationName),
        pickupName = pickupName,
        pickupNameLong = pickupName,
        atContractPickup = atContractPickup,
        distance = active.routeDistance,
        slots = active.remainingAmount,
        units = active.units or material.units or "L",
        rewardMoney = active.remainingValue,
        quotedRewards = active.quotedRewards,
        deliveredAmount = active.deliveredAmount,
        inTransitAmount = active.inTransitAmount,
        remainingAmount = active.remainingAmount,
        paidMoney = active.paidMoney,
        remainingValue = active.remainingValue,
        abandonmentFine = active.abandonmentFine,
        standardLoad = active.standardLoad,
        standardLoadCount = active.loadCount,
        modifiers = {},
        enabled = atContractPickup and active.loadableAmount > 0,
        _transientMaterialMoveAmount = 0,
        bigMapIds = {},
      }
      for _, targetLocation in ipairs(activeData.targetLocations) do
        activeData._transientMaterialMoveAmount = activeData._transientMaterialMoveAmount + targetLocation.selectedAmount
      end
      if not atContractPickup then
        activeData.enabled = false
        activeData.disableReason = {type = "wrongPickup", label = string.format("Go to %s to load.", pickupName)}
      elseif active.loadableAmount <= 0 then
        activeData.enabled = false
        activeData.disableReason = {type = "inTransit", label = "All remaining material is already in transit."}
      end
      local label, desc = dParcelMods.getLabelAndShortDescription(material.type)
      table.insert(activeData.modifiers, {type = material.type, icon = dParcelMods.getModifierIcon(material.type), active = true, label = label, description = desc})
      table.insert(data, 1, activeData)
      addCard(activeData)
    end
  end
  end
  return data
end


---------------------------------------------
-- main cargo information getter functions --
---------------------------------------------

M.deliveryScreenExternalButtonPressed = function(id)
  local branchKey = "careerSkills"
  local branch = career_branches.getBranchById(branchKey)
  if not branch or branch.missing then
    branchKey = "labourer"
  end
  if id == "openDeliveryProgress" then
    guihooks.trigger('ChangeState', {state = 'career.branchPage', params = {pathId = 'logistics-delivery'}})
  end
  if id == "openVehicleDeliveryProgress" then
    guihooks.trigger('ChangeState', {state = 'career.branchPage', params = {pathId = 'logistics-vehicleDelivery'}})
  end
end

-- gets all offers and player cargo, depending on supplied facId and psPath.
local function requestCargoDataForUi(facId, psPath, updateMaxTimeTimestamp)
  if cargoOverviewScreenOpen then
    cargoOverviewUiReady = true
  end
  cargoDataRequestSerial = cargoDataRequestSerial + 1
  local requestSerial = cargoDataRequestSerial
  if updateMaxTimeTimestamp ~= false then
    cargoOverviewMaxTimeTimestamp = dGeneral.time()
    cargoOverviewScreenOpenedTime = cargoOverviewMaxTimeTimestamp - pastDeliveryTimespan
  end
  sentNewCargoNotificationAlready = false
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    if requestSerial ~= cargoDataRequestSerial then return end
    local logisticsProgressBranchKey = "careerSkills"
    local progressBranch = career_branches.getBranchById(logisticsProgressBranchKey)
    if not progressBranch or progressBranch.missing then
      logisticsProgressBranchKey = "labourer"
    end

    local uiData = {
      player = {
        vehicles = {},
      },
      availableSystems = {},
      settings = dGeneral.getSettings(),
      tutorialInfo = dTutorial.getTutorialInfo(),
      facilityPanels = {
        {
          type = "skill",
          skillInfo = career_modules_branches_landing.getBranchSkillCardData("logistics-delivery"),
          branchId = logisticsProgressBranchKey, skillId="logistics-delivery",
          filterValueButtons = {'parcel','trailer','material','vehicle'},
          heading = "Logistics",
          description = 'Deliver parcels, trailers, materials, and car jockey jobs to level one unified logistics skill.',
          externalButtons = { {
            type = "progress",
            label = _tr("ui.career.cargoOverview.progress"),
            externalButtonId = 'openDeliveryProgress',
          } }
        }, {
          type = "services",
          filterValueButtons = {'loaner'},
          heading = _tr("ui.career.cargoOverview.servicesHeading"),
          description = _tr("ui.career.cargoOverview.servicesDescription"),
          externalButtons = {
            {
              type = "reputaion",
              label = _tr("ui.career.cargoOverview.viewReputationDetails"),
              externalButtonId = 'reputation',
            }
          }

        }
      },
      levelInfo = {
        name = career_modules_uiUtils.getCareerCurrentLevelName().title
      }
    }

    local hasTooFastVehicle = false
    for _, con in ipairs(playerCargoContainers) do
      if not hasTooFastVehicle then
        local veh = scenetree.findObjectById(con.vehId)
        if veh then
          hasTooFastVehicle = veh:getVelocity():length() > 0.25
        end
      end
    end
    uiData.player.isMoving = hasTooFastVehicle


    table.clear(cardsById)
    cardId = 0
    local facPsLocation
    if facId and facId ~= "undefined" then
      local fac = dGenerator.getFacilityById(facId)
      fac.progress.interacted = true
      local organization = freeroam_organizations.getUIDataForOrg(fac.associatedOrganization)
      uiData.facility = {
        name = fac.name,
        longDescription = fac.facilityInformation or _tr("ui.career.cargoOverview.noFacilityInformation"),
        id = fac.id,
        preview = fac.preview,
        outgoingCargo = {},
        trailerOffers = {},
        vehicleOffers = {},
      }
      if organization then
        career_career.interactWithOrganization(fac.associatedOrganization)
        uiData.facility.organization = organization
        if fac.hasLoanerSpots then
          local loanersFormatted = career_modules_loanerVehicles.formatLoanerOfferForUi(fac) or {}
          for _, item in ipairs(loanersFormatted) do
            item.cardType = "loaner"
            item.isFacilityCard = true
            addCard(item)

            if item.spawnWhenCommitingCargo then
              local copy = deepcopy(item)
              copy.isFacilityCard = false
              copy.isPlayerCard = true
              addCard(copy)
            end
          end
        end

        for _, item in ipairs(career_modules_loanerVehicles.formatSpawnedLoanersForUi()) do
          item.isFacilityCard = false
          item.isPlayerCard = true
          item.cardType = "loaner"
          addCard(item)
        end
      end

      uiData.availableSystems = deepcopy(fac.providedSystemsLookup or {})
      -- patch in large delivery systems
      uiData.availableSystems.largeFluidDelivery = uiData.availableSystems.largeFluidDelivery or fac.receivedSystemsLookup.largeFluidDelivery
      uiData.availableSystems.largeDryBulkDelivery = uiData.availableSystems.largeDryBulkDelivery or fac.receivedSystemsLookup.largeDryBulkDelivery
      uiData.availableSystems.largeCementDelivery = uiData.availableSystems.largeCementDelivery or fac.receivedSystemsLookup.largeCementDelivery
      uiData.availableSystems.largeCashDelivery = uiData.availableSystems.largeCashDelivery or fac.receivedSystemsLookup.largeCashDelivery

      if psPath and psPath ~= "undefined" then
        local ps = dGenerator.getParkingSpotByPath(psPath)
        facPsLocation = {type = "facilityParkingspot", facId = facId, psPath = psPath}

        -- add all parcels at this location
        --local outgoingCargo = dParcelManager.getAllCargoCustomFilter(function() return true end)
        local outgoingCargo = dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(facId, cargoOverviewScreenOpenedTime, cargoOverviewMaxTimeTimestamp)
        uiData.facility.outgoingCargo = clusterFormatCargo(outgoingCargo, playerCargoContainers, true)

        -- add all vehicle and trailer offers at this location
        local vehOffers = dVehOfferManager.getAllOfferAtFacilityUnexpired(facId, psPath)
        local vehs, trailers = {}, {}
        for _, offer in ipairs(vehOffers) do
          if offer.data.type == "vehicle" then
            table.insert(vehs, offer)
          else
            table.insert(trailers, offer)
          end
        end
        if fac.providedSystemsLookup.vehicleDelivery then
          uiData.facility.vehicleOffers = formatVehicleOfferForUi(vehs)
        end
        if fac.providedSystemsLookup.trailerDelivery then
          uiData.facility.trailerOffers = formatVehicleOfferForUi(trailers)
        end

      end

      -- Contract offers belong to the facility, not to the parking spot used to
      -- open the cargo screen. Keep loading eligibility tied to facPsLocation,
      -- but always expose the offer pool from the facility overview/phone path.
      if next(fac.materialStorages) then
        uiData.facility.materialStorageData = formatMaterialStorage(fac, facPsLocation, playerCargoContainers)
      end
    end

    -- Player Data

    -- aggregates of money, weight etc
    local playerMoneySum, playerWeightSum, playerMoneySumNonTransient = 0, 0 ,0
    -- helper for distance calculation
    table.clear(vehToLocationDistanceCache)
    -- to see if the player can load different types of cargo
    local hasContainersOfCargoType = {}

    -- handle each container individually
    for _, con in ipairs(playerCargoContainers) do
      local entry = {
        vehId = con.vehId,
        name = con.name,
        moveToLabel = con.moveToLabel,
        cargoTypesLookup = con.cargoTypesLookup,
        cargoTypesString = con.cargoTypesString,
        totalCargoSlots = con.totalCargoSlots,
        usedCargoSlots = con.usedCargoSlots,
        freeCargoSlots = con.freeCargoSlots,
        transientCargoSlots = con.transientCargoSlots,
        cargo = clusterFormatCargo(con.rawCargo, nil),
        weight = 0,
        taskList = {},
      }
      for _, formatted in ipairs(entry.cargo) do
        formatted.nextTasks = {{label=core_locales.contextTranslate("ui.career.delivery.cargoScreen.bringTo", {destination = formatted.destinationName}), checked = false}}
        formatted.taskList = {core_locales.contextTranslate("ui.career.delivery.cargoScreen.deliverTo", {destination = formatted.destinationName})}
      end

      for _, formatted in ipairs(clusterFormatCargo(con.transientCargo)) do
        formatted.transientMove = true
        formatted.nextTasks = { }
        if facPsLocation and dParcelManager.sameLocation(formatted.location, facPsLocation) then
          formatted.nextTasks[1] = {label=_tr("ui.career.delivery.cargoScreen.loadingHere"), checked = true}
          formatted.taskList = {core_locales.contextTranslate("ui.career.delivery.cargoScreen.deliverTo", {destination = formatted.destinationName})}
        else
          formatted.nextTasks[1] = {label=core_locales.contextTranslate("ui.career.delivery.cargoScreen.loadAt", {location = formatted.locationNameLong}), checked = false}
          formatted.taskList = {core_locales.contextTranslate("ui.career.delivery.cargoScreen.pickUpAt", {location = formatted.locationNameLong})}
        end
        formatted.nextTasks[2] = {label=core_locales.contextTranslate("ui.career.delivery.cargoScreen.bringTo", {destination = formatted.destinationNameLong}), checked = false}

        table.insert(entry.cargo, formatted)
      end
      -- player can load the cargo of this containers cargo type
      hasContainersOfCargoType[con.cargoTypesString] = true

      -- go through each item in this container
      for _, cargo in ipairs(entry.cargo) do
        -- enable systems for this type, even if the facilitiy does not offer it
        if cargo.type == "parcel" then
          uiData.availableSystems.parcelDelivery = true
        end
        if cargo.type == "fluid" then
          uiData.availableSystems.smallFluidDelivery = true
        end
        if cargo.type == "dryBulk" then
          uiData.availableSystems.smallDryBulkDelivery = true
        end    
        if cargo.type == "cement" then
          uiData.availableSystems.smallCementDelivery = true
        end
        if cargo.type == "cash" then
          uiData.availableSystems.smallCashDelivery = true
        end

        -- add money and weight to sums
        playerMoneySum = playerMoneySum + #cargo.ids * cargo.rewardMoney
        entry.weight = entry.weight + cargo.weight * #cargo.ids


        -- calculate how far is is to this cargos destintaion (using cache)
        if cargo.destination.type == "facilityParkingspot" then
          local distanceKey = string.format("%d-%s-%s", con.vehId, cargo.destination.facId, cargo.destination.psPath)
          if vehToLocationDistanceCache[distanceKey] == nil then
            vehToLocationDistanceCache[distanceKey] = false
            local a, b = dGenerator.getLocationCoordinates(cargo.location), dGenerator.getLocationCoordinates(cargo.destination)
            if a and b then
              vehToLocationDistanceCache[distanceKey] = dGenerator.distanceBetween(a,b)
            end
          end
          cargo.distance = vehToLocationDistanceCache[distanceKey] or nil
        end

        -- figure out where this cargo item can be moved to
        cargo.targetLocations = {}
        -- check other conatiners if it can go there
        for _, otherCon in ipairs(playerCargoContainers) do
          --if cargo is fluid or materials, can only go in other containers with the same fluid/materials
          local isMixable = dGenerator.isMixable(cargo.materialType)
          local validTarget = true
          if not isMixable then
            local materialType = cargo.materialType
            for _, otherCargo in ipairs(otherCon.rawCargo) do
              validTarget = validTarget and otherCargo.materialType == cargo.materialType
            end
          end

          if validTarget and otherCon.cargoTypesLookup[cargo.type] then
            local loc = {
              label = otherCon.moveToLabel,
              location = otherCon.location,
              enabled = otherCon.freeCargoSlots >= cargo.slots,
              maxAmount = math.min(math.floor(otherCon.freeCargoSlots / cargo.slots), #cargo.ids),
              containerVehicleInfo = {
                vehId = con.vehId,
                vehName = con.vehName,
                conName = con.name,
              },
              usedCargoSlots = otherCon.usedCargoSlots,
              totalCargoSlots = otherCon.totalCargoSlots,
              selectedAmount = 0,
            }
            if con.containerId == otherCon.containerId then
              loc.maxAmount = #cargo.ids
              loc.usedCargoSlots = loc.usedCargoSlots - cargo.slots * #cargo.ids
              loc.selectedAmount = #cargo.ids
            end
            if loc.maxAmount > 0 then
              table.insert(cargo.targetLocations, loc)
            end
          end
        end
        if not cargo.transientMove then
          cargo.throwAwayInfo = {
            penalty = cargo.rewardMoney * dGeneral.getDeliveryAbandonPenaltyFactor(),
            location = {type="deleted"},
          }
        end
        --[[ previously loaded items can also be "thrown away"
        table.insert(cargo.targetLocations, {label = "Throw Away", location = {type="deleted"}, enabled = true, icon="trashBin1", extraData = {}})]]

      end

      -- add up the total player weight
      playerWeightSum = playerWeightSum + entry.weight

      -- add a "vehicle" entry for this container is there is none. containers are grouped by vehicle in ui
      if not uiData.player.vehicles[entry.vehId] then
        uiData.player.vehicles[entry.vehId] = { containers = {}, niceName = dGeneral.getVehicleName(entry.vehId), vehId = entry.vehId, hasContainersOfCargoType = {}}
      end
      uiData.player.vehicles[entry.vehId].hasContainersOfCargoType[con.cargoTypesString] = true
      table.insert(uiData.player.vehicles[entry.vehId].containers, entry)

    end

    -- set player fields
    uiData.player.loadedCargoMoneySum = playerMoneySum
    uiData.player.penaltyForAbandon = dGeneral.getDeliveryModePenalty()
    uiData.player.weightSum = playerWeightSum
    uiData.player.noContainers = not next(playerCargoContainers)
    uiData.player.hasContainersOfCargoType = hasContainersOfCargoType


    -- convert vehicles table to list for UI
    local vehicleInfoList = {}
    for vehId, vehicleInfo in pairs(uiData.player.vehicles) do
      --table.sort(vehicleInfo.containers, function(a,b) return a.name < b.name end)
      table.insert(vehicleInfoList, vehicleInfo)
    end
    table.sort(vehicleInfoList, function(a,b) return a.vehId < b.vehId end)
    uiData.player.vehicles = vehicleInfoList

    -- add the accepted offers (ie spawned delivery vehicles) too
    uiData.player.acceptedOffers = getAcceptedVehicleOffers()
    for _, offer in ipairs(uiData.player.acceptedOffers) do
      if offer.type == "vehicle" then
        uiData.availableSystems.vehicleDelivery = true
      end
      if offer.type == "trailer" then
        uiData.availableSystems.trailerDelivery = true
      end
    end

    uiData.cardsById = cardsById
    uiData.filterSets = career_modules_delivery_cargoCards.resetFilterCounters()

    uiData.sortingSets = career_modules_delivery_cargoCards.getCardSortingSetsByKey(cardsById)
    uiData.facilityCardGroupSets = career_modules_delivery_cargoCards.getCardGroupSetsByKey(cardsById, false)
    uiData.playerCardGroupSets = career_modules_delivery_cargoCards.getCardGroupSetsByKey(cardsById, true, playerCargoContainers)

    career_modules_delivery_cargoCards.addSortingValuesToGroups(cardsById, uiData.facilityCardGroupSets)
    career_modules_delivery_cargoCards.addSortingValuesToGroups(cardsById, uiData.playerCardGroupSets)

    uiData.filterSets = career_modules_delivery_cargoCards.getFilterSets(cardsById)

    career_modules_delivery_cargoCards.addFilterPlayerData(uiData.filterSets, uiData.playerCardGroupSets, playerCargoContainers)

    uiData.confirmButtonInfo = career_modules_delivery_cargoCards.getConfirmButtonFromPlayerCards(uiData.cardsById)


    M.setVisibleIdsForBigMap()
    M.setCargoScreenTab(cargoOverviewTab)
    --freeroam_bigMapMode.setOnlyIdsVisible({})

    --dumpz(uiData.playerCardGroupSets)
    -- notify UI
    guihooks.trigger("cargoDataForUiReady", uiData)
    M.highlightCargoInPoi(freeroam_bigMapMode.selectedPoiId)
  end)
end
-- update for the screen
local function onCargoGenerated(cargo)
  if not cargoOverviewScreenOpen then return end
  if sentNewCargoNotificationAlready then return end
  if not cargoScreenFacId then return end
  if cargo.origin.facId ~= cargoScreenFacId then return end
  if cargoScreenPsPath and cargo.origin.psPath ~= cargoScreenPsPath then return end
  sentNewCargoNotificationAlready = true
  guihooks.trigger("newCargoAvailable")
end

M.requestCargoDataForUi = requestCargoDataForUi
M.onCargoGenerated = onCargoGenerated

local function setMaterialContractPickupRoute(contractId, showMessage)
  local active = dMaterialContracts and dMaterialContracts.getContractById(contractId)
  if not active or active.status ~= "active" or not active.origin then return false end
  local toPos = dGenerator.getLocationCoordinates(active.origin)
  if not toPos then return false end
  if dGeneral and dGeneral.setDeliveryNavFocus then
    dGeneral.setDeliveryNavFocus(toPos)
  else
    freeroam_bigMapMode.setNavFocus(toPos)
  end
  core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
  if showMessage ~= false then
    ui_message(string.format("Route set: go to %s loading point to load %s.", _tr(active.sourceName), _tr(active.materialName)), 6, "info")
  end
  return true
end
M.setMaterialContractPickupRoute = setMaterialContractPickupRoute

local function setMaterialContractDestinationRoute(contractId, showMessage)
  local active = dMaterialContracts and dMaterialContracts.getContractById(contractId)
  if not active or active.status ~= "active" or not active.destination then return false end
  local toPos = dGenerator.getLocationCoordinates(active.destination)
  if not toPos then return false end
  if dGeneral and dGeneral.setDeliveryNavFocus then
    dGeneral.setDeliveryNavFocus(toPos)
  else
    freeroam_bigMapMode.setNavFocus(toPos)
  end
  core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
  if showMessage ~= false then
    ui_message(string.format("Route set: deliver %s to %s.", _tr(active.materialName), _tr(active.destinationName)), 6, "info")
  end
  return true
end
M.setMaterialContractDestinationRoute = setMaterialContractDestinationRoute

local function isAtActiveMaterialPickup(contractId, facId, psPath)
  local active = dMaterialContracts and dMaterialContracts.getContractById(contractId)
  return active and active.status == "active" and active.origin
    and active.origin.facId == facId and active.origin.psPath == psPath
end

local function formatMaterialPickupData(playerCargoContainers)
  local active = dMaterialContracts and dMaterialContracts.getContractById(materialPickupContractId)
  if not active or active.status ~= "active" then
    return {available = false, reason = "There is no active material contract."}
  end
  if not isAtActiveMaterialPickup(materialPickupContractId, materialPickupFacId, materialPickupPsPath) then
    return {available = false, reason = "This is not the contract loading point."}
  end

  local material = dGenerator.getMaterialsTemplatesById(active.materialType)
  if not material then return {available = false, reason = "The contract material is unavailable."} end

  local equipment = {}
  local compatibleCapacity = 0
  for _, con in ipairs(playerCargoContainers or {}) do
    local supportsType = con.cargoTypesLookup and con.cargoTypesLookup[material.type]
    local carriesOtherMaterial = next(con.rawCargo or {}) and con.rawCargo[1].materialType ~= active.materialType
    local free = math.max(0, tonumber(con.freeCargoSlots) or 0)
    local eligible = supportsType and not carriesOtherMaterial and free > 0
    if eligible then compatibleCapacity = compatibleCapacity + free end
    local reason
    if not supportsType then
      reason = string.format("Not compatible with %s", _tr(material.name))
    elseif carriesOtherMaterial then
      reason = "Contains a different material"
    elseif free <= 0 then
      reason = "Container is full"
    end
    equipment[#equipment + 1] = {
      vehId = con.vehId,
      containerId = con.containerId,
      vehicleName = con.vehName or "Vehicle",
      containerName = con.name or "Cargo container",
      used = math.max(0, tonumber(con.usedCargoSlots) or 0),
      capacity = math.max(0, tonumber(con.totalCargoSlots) or 0),
      free = free,
      eligible = eligible and true or false,
      reason = reason,
    }
  end

  local loadable = math.max(0, tonumber(active.loadableAmount) or 0)
  local uiContract = deepcopy(active)
  uiContract.sourceName = _tr(active.sourceName)
  uiContract.destinationName = _tr(active.destinationName)
  uiContract.materialName = _tr(active.materialName)
  return {
    available = true,
    contract = uiContract,
    material = {name = _tr(material.name), type = material.type, units = active.units or material.units or "L"},
    equipment = equipment,
    compatibleCapacity = compatibleCapacity,
    maximumLoad = math.min(loadable, compatibleCapacity),
    loading = materialPickupLoadInProgress,
  }
end

local function requestMaterialContractPickupData()
  if not materialPickupScreenOpen then return false end
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    if materialPickupScreenOpen then
      guihooks.trigger("materialContractPickupData", formatMaterialPickupData(playerCargoContainers))
    end
  end)
  return true
end
M.requestMaterialContractPickupData = requestMaterialContractPickupData

local function closeMaterialContractPickupScreen(setRoute)
  local contractId = materialPickupContractId
  materialPickupScreenOpen = false
  materialPickupFacId, materialPickupPsPath, materialPickupContractId = nil, nil, nil
  materialPickupLoadInProgress = false
  simTimeAuthority.pause(false)
  if setRoute == true then setMaterialContractDestinationRoute(contractId, false) end
  guihooks.trigger("ChangeState", {state = "play"})
  gameplay_markerInteraction.setForceReevaluateOpenPrompt()
end
M.closeMaterialContractPickupScreen = closeMaterialContractPickupScreen
M.onMaterialContractPickupRouteLeave = function()
  materialPickupScreenOpen = false
  materialPickupFacId, materialPickupPsPath, materialPickupContractId = nil, nil, nil
  materialPickupLoadInProgress = false
  simTimeAuthority.pause(false)
end

local function enterMaterialContractPickupScreen(contractId, facId, psPath)
  if not isAtActiveMaterialPickup(contractId, facId, psPath) then
    ui_message("Go to the contract's marked loading point to load material.", 5, "warning")
    setMaterialContractPickupRoute(contractId, false)
    return false
  end
  materialPickupFacId, materialPickupPsPath, materialPickupContractId = facId, psPath, contractId
  materialPickupScreenOpen = true
  materialPickupLoadInProgress = false
  gameplay_markerInteraction.closeViewDetailPrompt(true)
  simTimeAuthority.pause(true)
  guihooks.trigger("ChangeState", {state = "career.materialContractPickup"})
  return true
end
M.enterMaterialContractPickupScreen = enterMaterialContractPickupScreen

local function loadMaterialContract(contractId, amount)
  if not materialPickupScreenOpen or materialPickupLoadInProgress or contractId ~= materialPickupContractId then return false end
  materialPickupLoadInProgress = true
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    local active = dMaterialContracts and dMaterialContracts.getContractById(contractId)
    local material = active and dGenerator.getMaterialsTemplatesById(active.materialType)
    local fac = active and dGenerator.getFacilityById(active.sourceFacId)
    local facStorage = fac and fac.materialStorages and fac.materialStorages[active.materialType]
    if not active or not material or not facStorage or not isAtActiveMaterialPickup(contractId, materialPickupFacId, materialPickupPsPath) then
      materialPickupLoadInProgress = false
      guihooks.trigger("materialContractPickupResult", {success = false, message = "The contract loading point is no longer available."})
      requestMaterialContractPickupData()
      return
    end

    local requested = math.min(math.max(0, tonumber(amount) or 0), active.loadableAmount or 0)
    local eligible = {}
    for _, con in ipairs(playerCargoContainers or {}) do
      local supportsType = con.cargoTypesLookup and con.cargoTypesLookup[material.type]
      local sameOrEmpty = not next(con.rawCargo or {}) or con.rawCargo[1].materialType == active.materialType
      if supportsType and sameOrEmpty and (con.freeCargoSlots or 0) > 0 then eligible[#eligible + 1] = con end
    end
    table.sort(eligible, function(a, b)
      local aSame = next(a.rawCargo or {}) and 1 or 0
      local bSame = next(b.rawCargo or {}) and 1 or 0
      if aSame ~= bSame then return aSame > bSame end
      return (a.freeCargoSlots or 0) < (b.freeCargoSlots or 0)
    end)

    local remaining = requested
    local loaded = 0
    for _, con in ipairs(eligible) do
      if remaining <= 0 then break end
      local loadAmount = math.min(remaining, con.freeCargoSlots or 0)
      if loadAmount > 0 and dGenerator.addMaterialAsParcelToContainer(con, facStorage, loadAmount, active.sourceFacId, active.origin.psPath, active.id) then
        remaining = remaining - loadAmount
        loaded = loaded + loadAmount
      end
    end

    if loaded > 0 then
      dParcelManager.applyTransientMoves(active.origin)
      if not dGeneral.isDeliveryModeActive() then dGeneral.startDeliveryMode() end
      dGeneral.requestUpdateContainerWeights()
      if career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then
        career_modules_delivery_tasklist.sendCargoToTasklist()
      end
      if dMaterialContracts.refreshTaskGuidance then dMaterialContracts.refreshTaskGuidance(true) end
      Engine.Audio.playOnce("AudioGui", "event:>UI>Missions>Info_Open")
      guihooks.trigger("materialContractPickupResult", {
        success = true,
        amount = loaded,
        message = string.format("Loaded %d %s. Deliver it to %s.", math.floor(loaded + 0.5), active.units or "L", _tr(active.destinationName)),
      })
      closeMaterialContractPickupScreen(true)
    else
      materialPickupLoadInProgress = false
      guihooks.trigger("materialContractPickupResult", {success = false, message = "No compatible free container space is nearby."})
      requestMaterialContractPickupData()
    end
  end)
  return true
end
M.loadMaterialContract = loadMaterialContract

-- The cargo screen is part of the UI bridge's stable, startup-loaded surface.
-- Material contracts are loaded later with career delivery modules, so calling
-- their manager directly from Vue leaves the button pointing at an undefined
-- bridge module. Keep UI actions on this registered facade and always refresh
-- after an attempt: a failed acceptance may have expired an infeasible offer.
M.acceptMaterialContract = function(contractId)
  local accepted = dMaterialContracts and dMaterialContracts.acceptContract(contractId) or false
  if accepted then
    local active = dMaterialContracts.getContractById(contractId)
    local atPickup = active and active.origin and active.origin.facId == cargoScreenFacId and active.origin.psPath == cargoScreenPsPath
    if M.exitCargoOverviewScreen then M.exitCargoOverviewScreen() end
    if atPickup then
      enterMaterialContractPickupScreen(active.id, active.origin.facId, active.origin.psPath)
    else
      setMaterialContractPickupRoute(active.id, false)
    end
  end
  if cargoOverviewScreenOpen then
    requestCargoDataForUi(cargoScreenFacId, cargoScreenPsPath, false)
  end
  return accepted
end

M.abandonMaterialContract = function(contractId)
  local abandoned = dMaterialContracts and dMaterialContracts.abandonContract(contractId) or false
  if cargoOverviewScreenOpen then
    requestCargoDataForUi(cargoScreenFacId, cargoScreenPsPath, false)
  end
  return abandoned
end

-------------------------------------------
-- Loading and Unloading Cargo functions --
-------------------------------------------

-- call this function to move the cargo to a different location. if moved to the player, a transient flag will be added. if moved back to facility, transient flag will be removed.
local function moveCargoFromUi(cargoId, targetLocation)
  --dParcelManager.changeCargoLocation(cargoId, targetLocation, true)
  dParcelManager.addTransientMoveCargo(cargoId, targetLocation)
  --[[
  for poiId, list in pairs(visibleBigMapIdsToCardIds) do
    for _, cargo in ipairs(list) do
      --dump(cargoId, cargo.id)
      if cargo.id == cargoId then
        --dump(poiId)
        --dump(freeroam_bigMapMode.navigateToMission(poiId))
        return
      end
    end
  end
  ]]
end
M.applyTransientMoves = function()
  dParcelManager.applyTransientMoves()
end


-- offer spawning is handled in vehOffermanager
M.spawnOffer = function(...) return dVehOfferManager.spawnOffer(...) end

local function toggleOfferForSpawning(offerId)
  local offer = dVehOfferManager.getOfferById(offerId)
  offer.spawnWhenCommitingCargo = not offer.spawnWhenCommitingCargo
end
M.toggleOfferForSpawning = toggleOfferForSpawning





M.moveCargoFromUi = moveCargoFromUi


-------------------------------------------
-- Entering and Exiting the Cargo Screen --
-------------------------------------------

-- Big map rewrites TOD/fog/clouds via core_environment. Lock those setters while the
-- cargo overview owns big map so the sky look stays on the rolling career clock.
local cargoEnvChangesLocked = false

local function lockCargoEnvChanges()
  if cargoEnvChangesLocked then return end
  cargoEnvChangesLocked = true
  if core_environment and core_environment.enableChanges then
    core_environment.enableChanges(false)
  end
end

local function unlockCargoEnvChanges()
  if not cargoEnvChangesLocked then return end
  cargoEnvChangesLocked = false
  if core_environment and core_environment.enableChanges then
    core_environment.enableChanges(true)
  end
end

local exitCargoOverviewScreen

-- If Vue never mounts, big-map stays kilometers up with no UI. After this timeout,
-- take the same close path as the cargo screen's Close button.
local function scheduleCargoOverviewUiReadyWatchdog()
  local token = cargoOverviewEnterToken
  core_jobsystem.create(function(job)
    job.sleep(CARGO_OVERVIEW_UI_READY_TIMEOUT)
    if token ~= cargoOverviewEnterToken then return end
    if not cargoOverviewScreenOpen or cargoOverviewUiReady then return end
    log("W", "cargoScreen", "Cargo overview UI did not mount; exiting after timeout")
    exitCargoOverviewScreen()
  end)
end

-- called by activity accept or from the career menu to enter the cargo screen.
local function enterCargoOverviewScreen(facilityId, parkingSpotPath)
  vehicleSpawnInProgress = false
  pendingTransientMoves = false
  if career_modules_loanerVehicles and career_modules_loanerVehicles.unmarkAllForSpawning then
    career_modules_loanerVehicles.unmarkAllForSpawning()
  end
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    cargoOverviewScreenOpen = true
    cargoOverviewUiReady = false
    cargoOverviewEnterToken = cargoOverviewEnterToken + 1
    cargoOverviewTab = ""
    cargoScreenFacId, cargoScreenPsPath = facilityId, parkingSpotPath
    cargoOverviewScreenOpenedTime = dGeneral.time() - pastDeliveryTimespan
    cargoOverviewMaxTimeTimestamp = dGeneral.time()

    -- Trigger tutorial generator if this is the tutorial facility
    if facilityId then
      local isCargoDeliveryTutorialActive = dTutorial.isCargoDeliveryTutorialActive()
      local isVehicleDeliveryTutorialActive = dTutorial.isVehicleDeliveryTutorialActive()
      local fac = dGenerator.getFacilityById(facilityId)

      if isCargoDeliveryTutorialActive and fac and fac.isTutorialForCargoDelivery then
        -- Trigger all tutorial generators at this facility
        for _, generator in ipairs(fac.logisticGenerators or {}) do
          if generator.isTutorialGenerator then
            dGenerator.triggerGenerator(fac, generator)
          end
        end
      end

      if isVehicleDeliveryTutorialActive and fac and fac.isTutorialForVehicleDelivery then
        -- Trigger all tutorial vehicle generators at this facility
        for _, generator in ipairs(fac.logisticGenerators or {}) do
          if generator.isTutorialGenerator then
            dGenerator.triggerGenerator(fac, generator)
          end
        end
      end
    end

    gameplay_rawPois.clear()

    local options = {
      instant = true,
      cameraAdditionalHeightFactor = 0.65,
      horizontalOffsetFactor = 0,
      verticalOffsetFactor = 5,
      navigationBoundariesFactor = 1.5
    }
    lockCargoEnvChanges()
    freeroam_bigMapMode.enterBigMapWithCustomPOIs({}, M.deliveryMarkerSelected, options)
    if facilityId == nil and parkingSpotPath == nil then
      guihooks.trigger('ChangeState', {state = 'career.cargoOverview', params = {}})
    else
      guihooks.trigger('ChangeState', {state = 'career.cargoOverview', params = {facilityId = facilityId, parkingSpotPath = parkingSpotPath}})
    end
    extensions.hook("onEnterCargoOverviewScreen")
    scheduleCargoOverviewUiReadyWatchdog()
  end)
end
local function enterMyCargo() enterCargoOverviewScreen() end
M.enterMyCargo = enterMyCargo

-- called whenever the cargo screen is closed for any reason.
exitCargoOverviewScreen = function(facilityId, parkingSpotPath)
  cargoOverviewScreenOpen = false
  cargoOverviewUiReady = false
  cargoOverviewEnterToken = cargoOverviewEnterToken + 1
  cargoDataRequestSerial = cargoDataRequestSerial + 1
  gameplay_rawPois.clear()
  if dGeneral and dGeneral.requestDeliveryPoiRefresh then
    dGeneral.requestDeliveryPoiRefresh(true)
  end
  --career_career.closeAllMenus()
  freeroam_bigMapMode.exitBigMap(true)
  unlockCargoEnvChanges()
  simTimeAuthority.pause(false) -- this is only necessary because the career pause menu doesnt unpause in time for the bigMap to start, so the bigMap will not unpause by itself
  if not vehicleSpawnInProgress and not pendingTransientMoves then
    if career_modules_loanerVehicles and career_modules_loanerVehicles.unmarkAllForSpawning then
      career_modules_loanerVehicles.unmarkAllForSpawning()
    end
  end
  if not vehicleSpawnInProgress then
    dGeneral.requestUpdateContainerWeights()
  end
  if not vehicleSpawnInProgress and not pendingTransientMoves then
    dGeneral.checkExitDeliveryMode()
  end
end

-- call this function to commit the configuration and clear all transient flags.
local function commitDeliveryConfiguration()
  local vehiclesToRefreshWeights = {}
  local function snapshotVehiclesToRefreshWeights()
    if dGeneral.rememberCurrentCargoWeightVehicles then
      dGeneral.rememberCurrentCargoWeightVehicles()
    end
    for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles() or {}) do
      if cargo.location and cargo.location.vehId then
        vehiclesToRefreshWeights[cargo.location.vehId] = true
      end
    end
    if dParcelManager.getTransientMoveCargo then
      for _, cargo in ipairs(dParcelManager.getTransientMoveCargo() or {}) do
        if cargo.location and cargo.location.vehId then
          vehiclesToRefreshWeights[cargo.location.vehId] = true
        end
        local target = cargo._transientMove and cargo._transientMove.targetLocation
        if target and target.vehId then
          vehiclesToRefreshWeights[target.vehId] = true
        end
      end
    end
  end
  snapshotVehiclesToRefreshWeights()

  local function buildSpawnStepsForCommit()
    local stepsList = {}
    local vehOffers = dVehOfferManager.getAllOfferUnexpired()
    for _, offer in ipairs(vehOffers) do
      if offer.spawnWhenCommitingCargo and offer.origin.facId == cargoScreenFacId then
        local offerSteps = (dVehOfferManager.makeSpawnOfferSteps and dVehOfferManager.makeSpawnOfferSteps(offer.id, false, 0.5)) or {}
        for _, st in ipairs(offerSteps) do
          table.insert(stepsList, st)
        end
      end
    end
    return stepsList
  end

  local function deferVehicleTransientMovesIfNeeded(hasVehicleOfferSpawns)
    local allTransientCargo = dParcelManager.getTransientMoveCargo()
    local deferredCargo = {}
    local heldParcelMoves = 0
    hasVehicleOfferSpawns = hasVehicleOfferSpawns == true
    
    local deletionsToApply = {}
    
    for _, cargo in ipairs(allTransientCargo) do
      if cargo and cargo._transientMove and cargo._transientMove.targetLocation then
        local targetLoc = cargo._transientMove.targetLocation
        if targetLoc.type == "deleted" then
          table.insert(deletionsToApply, cargo.id)
          dParcelManager.clearTransientMoveForCargo(cargo.id)
        end
      end
    end
    
    for _, cargoId in ipairs(deletionsToApply) do
      dParcelManager.changeCargoLocation(cargoId, {type="deleted"})
    end
    
    for _, cargo in ipairs(allTransientCargo) do
      if cargo and cargo._transientMove and cargo._transientMove.targetLocation then
        local targetLoc = cargo._transientMove.targetLocation
        if targetLoc.type ~= "deleted" then
          -- Starting a trailer job must not also finalize parcel loading. Keep
          -- parcels at their provider so the player can collect them after the
          -- trailer has been spawned, instead of silently loading both jobs
          -- as one commit.
          if hasVehicleOfferSpawns and cargo.type == "parcel" then
            heldParcelMoves = heldParcelMoves + 1
            dParcelManager.clearTransientMoveForCargo(cargo.id)
          elseif hasVehicleOfferSpawns then
            local involvesVehicle = targetLoc.type == "vehicle" or (cargo.location and cargo.location.type == "vehicle")
            if involvesVehicle then
              local copiedTargetLoc = {}
              for k, v in pairs(targetLoc) do
                copiedTargetLoc[k] = v
              end
              table.insert(deferredCargo, {
                cargoId = cargo.id,
                targetLocation = copiedTargetLoc
              })
              dParcelManager.clearTransientMoveForCargo(cargo.id)
            end
          end
        end
      end
    end

    if hasVehicleOfferSpawns then
      local remainingVehicleMoves = dParcelManager.getTransientMoveCargo()
      for _, cargo in ipairs(remainingVehicleMoves) do
        if cargo and cargo._transientMove and cargo._transientMove.targetLocation then
          local targetLoc = cargo._transientMove.targetLocation
          local involvesVehicle = targetLoc.type == "vehicle" or (cargo.location and cargo.location.type == "vehicle")
          if involvesVehicle and targetLoc.type ~= "deleted" then
            log("W","",string.format("Warning: Vehicle-related transient move for cargo %s was not deferred!", cargo.id))
            dParcelManager.clearTransientMoveForCargo(cargo.id)
          end
        end
      end
    end

    local movedCargo, remainingCargo = dParcelManager.applyTransientMoves({type="facilityParkingspot",facId=cargoScreenFacId, psPath=cargoScreenPsPath})

    log("I","",string.format("Commited Delivery Configuration. (Cargo Added: %d. Remaining to be loaded: %d. Deferred vehicle moves: %d. Held parcel moves: %d. Deletions applied: %d)",#movedCargo, #remainingCargo, #deferredCargo, heldParcelMoves, #deletionsToApply))
    return movedCargo, remainingCargo, deferredCargo
  end

  local function applyValidDeferredCargo(deferredCargo)
    local validDeferredCargo = {}
    for _, deferred in ipairs(deferredCargo) do
      local cargo = dParcelManager.getCargoById(deferred.cargoId)
      if cargo and cargo.location and cargo.location.type ~= "deleted" then
        table.insert(validDeferredCargo, deferred)
        dParcelManager.addTransientMoveCargo(deferred.cargoId, deferred.targetLocation)
      end
    end
    if #validDeferredCargo > 0 then
      dParcelManager.applyTransientMoves()
      log("I","",string.format("Applied %d deferred transient moves (filtered %d invalid)", #validDeferredCargo, #deferredCargo - #validDeferredCargo))
    end
    return validDeferredCargo
  end

  local spawnSteps = buildSpawnStepsForCommit()
  local hasVehicleOfferSpawnsFromSteps = spawnSteps and #spawnSteps > 0
  local movedCargo, remainingCargo, deferredCargo = deferVehicleTransientMovesIfNeeded(hasVehicleOfferSpawnsFromSteps)

  local allTransientCargo = dParcelManager.getTransientMoveCargo()
  pendingTransientMoves = #allTransientCargo > 0 or #deferredCargo > 0

  if not career_modules_delivery_general.isDeliveryModeActive() and (#movedCargo > 0 or #remainingCargo > 0) then
    dGeneral.startDeliveryMode()
  end
  if career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then
    career_modules_delivery_tasklist.sendCargoToTasklist()
  end

  local function hasLoanersMarkedForSpawning()
    if not career_modules_loanerVehicles or not career_modules_loanerVehicles.formatLoanerOfferForUi then
      return false
    end
    if not cargoScreenFacId then
      return false
    end
    local fac = dGenerator.getFacilityById(cargoScreenFacId)
    if not fac or not fac.hasLoanerSpots then
      return false
    end
    local loanersFormatted = career_modules_loanerVehicles.formatLoanerOfferForUi(fac) or {}
    for _, item in ipairs(loanersFormatted) do
      if item.spawnWhenCommitingCargo then
        return true
      end
    end
    return false
  end

  local hasLoanersToSpawn = hasLoanersMarkedForSpawning()

  local parcelLoadQueue = {}
  local parcelLoadInProgress = false

  local function loadParcelsForVehicle(vehId, containerData, callback)
    local veh = scenetree.findObjectById(vehId)
    if not veh then
      if callback then callback() end
      return
    end

    core_vehicleBridge.executeAction(veh, "setCargoContainers", containerData or {}, "updateAll")
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      local maxForContainer = 0
      if vehCargoContainerData and vehCargoContainerData[1] then
        for _, container in ipairs(vehCargoContainerData[1]) do
          local rt = container.reachTargetTimeRemaining or 0
          maxForContainer = math.max(maxForContainer, rt)
        end
      end

      local delay = math.max(maxForContainer, 0)
      local sequence = {}

      if delay > 0 then
        delay = math.max(delay, 1)
        table.insert(sequence, step.makeStepWait(delay + 0.5))
      end

      table.insert(sequence, step.makeStepReturnTrueFunction(function()
        local v = scenetree.findObjectById(vehId)
        if v then
          core_vehicleBridge.executeAction(v, 'setFreeze', false)
        end
        gameplay_markerInteraction.setForceReevaluateOpenPrompt()
        return true
      end))

      step.startStepSequence(sequence, function()
        gameplay_markerInteraction.setForceReevaluateOpenPrompt()
        if callback then callback() end
      end)

      if delay > 0 then
        guihooks.trigger("OpenSimpleDelayPopup",{timer=delay, heading=_tr("ui.career.delivery.general.loadingCargo")})
      end
      log("I","",string.format("Vehicle %d: %0.2fs delay after adjusting weights for cargo.", vehId, delay))
    end, "getCargoContainers")
  end

  local function tryStartNextParcelLoad()
    if parcelLoadInProgress then return end
    local req = table.remove(parcelLoadQueue, 1)
    if not req then return end

    parcelLoadInProgress = true
    loadParcelsForVehicle(req.vehId, req.containerData, function()
      parcelLoadInProgress = false
      if req.callback then req.callback() end
      tryStartNextParcelLoad()
    end)
  end

    local function loadParcelsForVehicleGroup(vehIds, callback)
    local updatePerVehicle = {}
    for _, vehId in ipairs(vehIds) do
      local veh = scenetree.findObjectById(vehId)
      if veh and veh:getJBeamFilename() ~= "unicycle" then
        updatePerVehicle[vehId] = {}
      end
    end

    for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
      if cargo.location.vehId and updatePerVehicle[cargo.location.vehId] then
        updatePerVehicle[cargo.location.vehId][cargo.location.containerId] = updatePerVehicle[cargo.location.vehId][cargo.location.containerId] or {
          volume = 0,
          density = 1,
          containerId = cargo.location.containerId
        }

        if cargo.type == "parcel" then
          updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume + (cargo.weight or 0)
        elseif cargo.type == "fluid" or cargo.type == "dryBulk" or cargo.type == "cement" or cargo.type == "cash" then
          updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume + (cargo.slots or 0)
          updatePerVehicle[cargo.location.vehId][cargo.location.containerId].density = (cargo.weight/cargo.slots or 1)
        end
      end
    end

    parcelLoadQueue = {}
    for vehId, containerData in pairs(updatePerVehicle) do
      local vid = vehId
      local cdata = containerData
      table.insert(parcelLoadQueue, {
        vehId = vid,
        containerData = cdata,
        callback = function()
          log("I","",string.format("Finished loading parcels for vehicle %d", vid))
        end
      })
    end

    if #parcelLoadQueue > 0 then
      log("I","",string.format("Queueing %d vehicles for parcel loading", #parcelLoadQueue))
      local parcelsLoaded = 0
      local totalParcels = #parcelLoadQueue
      
      local function onParcelLoadComplete()
        parcelsLoaded = parcelsLoaded + 1
        if parcelsLoaded >= totalParcels then
          if callback then callback() end
        end
      end
      
      for _, req in ipairs(parcelLoadQueue) do
        local originalCallback = req.callback
        req.callback = function()
          if originalCallback then originalCallback() end
          onParcelLoadComplete()
        end
      end
      
      tryStartNextParcelLoad()
    else
      if callback then callback() end
    end
  end

  local function getVehicleIdsForCargoLoad()
    local vehIdsLookup = {}
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId then
      vehIdsLookup[playerVehId] = true
    end

    for vehId in pairs(vehiclesToRefreshWeights) do
      vehIdsLookup[vehId] = true
    end

    for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
      if cargo.location and cargo.location.vehId then
        vehIdsLookup[cargo.location.vehId] = true
      end
    end

    local vehIds = {}
    for vehId in pairs(vehIdsLookup) do
      local veh = scenetree.findObjectById(vehId)
      if veh and veh:getJBeamFilename() ~= "unicycle" then
        table.insert(vehIds, vehId)
      end
    end
    return vehIds
  end

  local function finishCommit()
    vehicleSpawnInProgress = false
    local postCommitTransientCargo = dParcelManager.getTransientMoveCargo()
    pendingTransientMoves = #postCommitTransientCargo > 0
    gameplay_rawPois.clear()
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end

  local function afterLoanersSpawned()
    applyValidDeferredCargo(deferredCargo)
    deferredCargo = {} -- clear reference for GC

    local vehIdsToLoad = getVehicleIdsForCargoLoad()
    if next(vehIdsToLoad) then
      loadParcelsForVehicleGroup(vehIdsToLoad, finishCommit)
    else
      finishCommit()
    end
  end

  if hasVehicleOfferSpawnsFromSteps or #deferredCargo > 0 then
    vehicleSpawnInProgress = true
    local vehicleSpawnSequence = {}
    table.insert(vehicleSpawnSequence, step.makeStepFadeToBlack(0.4))
    
    for _, st in ipairs(spawnSteps) do
      table.insert(vehicleSpawnSequence, st)
    end

    table.insert(vehicleSpawnSequence, step.makeStepReturnTrueFunction(function()
      gameplay_markerInteraction.setForceReevaluateOpenPrompt()
      return true
    end))

    table.insert(vehicleSpawnSequence, step.makeStepFadeFromBlack(0.4))

    step.startStepSequence(vehicleSpawnSequence, function()
      career_modules_loanerVehicles.spawnAllOffers(afterLoanersSpawned)
    end)
  elseif hasLoanersToSpawn then
    -- spawnAllOffers has its own fade. A dummy fade sequence here nested
    -- startStepSequence and skipped the loaner's fade-to-black.
    vehicleSpawnInProgress = true
    career_modules_loanerVehicles.spawnAllOffers(afterLoanersSpawned)
  else
    applyValidDeferredCargo(deferredCargo)
    deferredCargo = {} -- clear reference for GC
    
    local vehIdsToLoad = getVehicleIdsForCargoLoad()
    if next(vehIdsToLoad) then
      vehicleSpawnInProgress = true
      loadParcelsForVehicleGroup(vehIdsToLoad, function()
        finishCommit()
      end)
    else
      finishCommit()
    end
  end
end

-- call this function to cancel the delivery - all cargo will be placed back.
local function cancelDeliveryConfiguration()
  dParcelManager.clearAllTransientMoves()
  pendingTransientMoves = false
  vehicleSpawnInProgress = false
  for _, offer in ipairs(dVehOfferManager.getAllOfferCustomFilter(function() return true end)) do
    offer.spawnWhenCommitingCargo = nil
  end
  career_modules_loanerVehicles.unmarkAllForSpawning()
  dGeneral.getNearbyVehicleCargoContainers(nop)
  ui_message(_tr("ui.career.delivery.cargoScreen.cancelledDeliveryConfiguration"))
end

M.enterCargoOverviewScreen = enterCargoOverviewScreen
M.exitCargoOverviewScreen = exitCargoOverviewScreen
M.commitDeliveryConfiguration = commitDeliveryConfiguration
M.cancelDeliveryConfiguration = cancelDeliveryConfiguration


--------------------------------------
-- Route Planning and route display --
--------------------------------------

local routePlanner = require('gameplay/route/route')()
local function getDistanceBetweenPoints(pos1, pos2)
  routePlanner:setupPath(pos1, pos2)
  return routePlanner.path[1].distToTarget
end

local function getClosestNeighbor(sourceId, targetsById, result, onlyClosestTarget)
  local minDist = math.huge
  local minDistTarget
  targetsById[sourceId] = nil
  for otherFacId, targetData in pairs(targetsById) do
    local dist = targetData.distances[sourceId]
    if dist < minDist then
      minDistTarget = targetData
      minDist = dist
    end
  end
  table.insert(result, minDistTarget.pos)
  if tableSize(targetsById) <= 1 or onlyClosestTarget then return end
  getClosestNeighbor(minDistTarget.id, targetsById, result)
end

local function setBestRoute(onlyClosestTarget)
  local allCargo = career_modules_delivery_parcelManager.getAllCargoInVehicles(true)
  local vehicleTasks = career_modules_delivery_vehicleTasks.getVehicleTasks()

  -- Loaded contract cargo participates in the normal multi-stop route below.
  -- If none is loaded yet, guide to the oldest accepted loadable contract.
  local hasLoadedMaterialContract = false
  for _, cargo in ipairs(allCargo) do
    if cargo.data and cargo.data.materialContractId then
      hasLoadedMaterialContract = true
      break
    end
  end
  if not hasLoadedMaterialContract then
    for _, active in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
      if active.status == "active" and active.origin and (active.loadableAmount or 0) > 0 then
        if setMaterialContractPickupRoute(active.id, false) then
          freeroam_bigMapMode.resetRoute()
          return
        end
      end
    end
  end

  if vehicleTasks and next(vehicleTasks) then
    career_modules_delivery_vehicleTasks.navigateToNextTask()
    freeroam_bigMapMode.resetRoute()
    return
  end

  if tableIsEmpty(allCargo) then
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
    return
  end

  local targetsById = {player = {distances = {}}}
  local hasTargetableCargo = false
  local function addRouteTarget(target)
    if not target then return end
    if target.type == "facilityParkingspot" then
      local targetId = string.format("%s-%s", target.facId, target.psPath)
      if not targetsById[targetId] then
        local parkingSpot = dGenerator.getParkingSpotByPath(target.psPath)
        if not parkingSpot then return end
        hasTargetableCargo = true
        local targetData = {pos = parkingSpot.pos, location = target, id = targetId}
        local distToPlayer = getDistanceBetweenPoints(getPlayerVehicle(0):getPosition(), targetData.pos)
        targetData.distances = {player = distToPlayer}
        targetsById.player.distances[targetId] = distToPlayer
        targetsById[targetId] = targetData
      else
        hasTargetableCargo = true
      end
    elseif target.type == "multi" then
      -- pick the best out of the possible locations...
      -- which is simply the one which has the most
    end
  end

  for _, cargo in ipairs(allCargo) do
    local routeToDestination = (M.isCargoScreenOpen() and cargo.location.facId == cargoScreenFacId)
      or not cargo._transientMove
    if routeToDestination and cargo.data and cargo.data.materialContractId and dMaterialContracts then
      for _, contract in ipairs(dMaterialContracts.getContractsAcceptingMaterial(cargo.materialType)) do
        addRouteTarget(contract.destination)
      end
    else
      addRouteTarget(routeToDestination and cargo.destination or cargo.location)
    end
  end
  if not hasTargetableCargo then
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
    return
  end

  for tgtId1, targetData1 in pairs(targetsById) do
    for tgtId2, targetData2 in pairs(targetsById) do
      if tgtId1 ~= tgtId2 and tgtId1 ~= "player" and tgtId2 ~= "player" then
        targetData1.distances[tgtId2] = dGenerator.getDistanceBetweenFacilities(targetData1.location, targetData2.location)
      end
    end
  end

  local result = {}
  getClosestNeighbor("player", deepcopy(targetsById), result, onlyClosestTarget)
  core_groundMarkers.setPath(result, {clearPathOnReachingTarget = false})
  freeroam_bigMapMode.resetRoute()
end

-- recalculate route after closing the popup with the rewards
local function onDeliveryRewardsPopupClosed()
  -- recalculate the best route after delivering, because sometimes the the waypoint at the delivery spot doesnt count as "reached" for the groundmarkers and so it will keep pointing to it
  if career_modules_delivery_general.getSettings().automaticRoute then
    setBestRoute(true)
  end

  -- tell player they can take a taxi back, and show one-time
  -- 0.5 s delayed
  local sequence = {
    step.makeStepWait(0.5),
    step.makeStepReturnTrueFunction(function()
      career_modules_tutorialPopups.introPopup("delivery/cargoDelivered")
      if gameplay_walk.isWalking() then
        ui_message(_tr("ui.career.delivery.cargoScreen.takeTaxiHint"),6,"post_delivery","local_taxi")
        career_modules_tutorialPopups.introPopup("delivery/postDeliveryTaxi")
      end
      return true
  end)}
  step.startStepSequence(sequence)
end

local function onCargoPickedUp()
  -- recalculate the best route after delivering, because sometimes the the waypoint at the delivery spot doesnt count as "reached" for the groundmarkers and so it will keep pointing to it
  if career_modules_delivery_general.getSettings().automaticRoute then
    setBestRoute(true)
  end
end

-- Show only the route up until the first destination in gameplay
local function onDeactivateBigMapCallback()
  if career_modules_delivery_general.isDeliveryModeActive() and career_modules_delivery_general.getSettings().automaticRoute then
    setBestRoute(true)
  end
end

M.setBestRoute = setBestRoute
M.onCargoPickedUp = onCargoPickedUp
M.onDeliveryRewardsPopupClosed = onDeliveryRewardsPopupClosed
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback


---------------------------------------------------
-- clicking/hovering markers on the cargo screen --
---------------------------------------------------

-- highlight entries in list
local function highlightCargoInPoi(poiId)
  if not visibleBigMapIdsToCardIds[poiId] or not poiId then
    guihooks.trigger("sendHighlightedCardIds", {})
    return
  end
  local cardIds = {}
  for _, id in ipairs(freeroam_bigMapMarkers.getIdsFromHoveredPoiId(poiId)) do
    local elem = visibleBigMapIdsToCardIds[id]
    if elem then
      for cardId, _ in pairs(elem.cardIds) do
        cardIds[cardId] = true
      end
    end
  end

  guihooks.trigger("sendHighlightedCardIds", cardIds)
end

-- when a marker is clicked, set route there
local function deliveryMarkerSelected(poiId)

  highlightCargoInPoi(poiId)
  if not visibleBigMapIdsToCardIds[poiId] then return end
  if not dGeneral.isAutomaticRouteEnabled() then
    freeroam_bigMapMode.navigateToMission(poiId)
  end
end
M.deliveryMarkerSelected = deliveryMarkerSelected

-- when a marker is hovered, highlight entries in list
M.onBigmapHoveredPoiIdChanged = function(poiId)
  if not cargoOverviewScreenOpen then return end
  highlightCargoInPoi(poiId or freeroam_bigMapMode.selectedPoiId)
end

-- when a parcel list entry is hovered, preview the route on bigMap

local function showRoutePreview(route)
  if not route then freeroam_bigMapMode.clearRoutePreview() return end
  if route.type == "navgraph" then
    local unsimplifiedRoute = {}
    for _, loc in ipairs(route.locations) do
      if loc.type ~= "multi" then
        local pos =  dGenerator.getLocationCoordinates(loc)
        table.insert(unsimplifiedRoute, pos)
      end
    end
    if #unsimplifiedRoute > 1 then
      local routeUtil = require('/lua/ge/extensions/gameplay/route/route')()
      routeUtil:setupPathMulti(unsimplifiedRoute)
      freeroam_bigMapMode.setRoutePreview(routeUtil.path)
    else
      freeroam_bigMapMode.clearRoutePreview()
    end
  else
    freeroam_bigMapMode.clearRoutePreview()
  end
end
M.showRoutePreview = showRoutePreview


local function showCargoRoutePreview(cargoId)
  if cargoId == nil then
    freeroam_bigMapMode.clearRoutePreview()
    return
  end
  local cargo = dParcelManager.getCargoById(cargoId)
  if not cargo then return end

  if cargo.destination.type == "multi" then
    local route = {}
    local fromPos = dGenerator.getLocationCoordinates(cargo.location)
    for _, dest in ipairs(cargo.destination.destinations) do
      local toPos = dGenerator.getLocationCoordinates(dest)
      table.insert(route, {pos = fromPos})
      table.insert(route, {pos = toPos})
    end
    freeroam_bigMapMode.setRoutePreview(route)
  else
    local fromPos = dGenerator.getLocationCoordinates(cargo.location)
    local toPos = dGenerator.getLocationCoordinates(cargo.destination)
    if fromPos and toPos then
      freeroam_bigMapMode.setRoutePreviewSimple(fromPos, toPos)
    end
  end
end

-- when a vehicle offer list entry is hovered, preview route on bigMap
local function showVehicleOfferRoutePreview(offerId)
  if offerId == nil then
    freeroam_bigMapMode.clearRoutePreview()
    return
  end
  local offer = dVehOfferManager.getOfferById(offerId)
  if not offer then return end
  local fromPos = dGenerator.getLocationCoordinates(offer.locations[1])
  local toPos = dGenerator.getLocationCoordinates(offer.locations[2])
  if fromPos and toPos then
    freeroam_bigMapMode.setRoutePreviewSimple(fromPos, toPos)
  end
end

-- when a parcel list entry is hovered, preview the route on bigMap
local function showLocationRoutePreview(locationId, asProvider)
  if locationId == nil then
    freeroam_bigMapMode.clearRoutePreview()
    return
  end
  local fromPos = dGenerator.getLocationCoordinates({type="facilityParkingspot",facId = cargoScreenFacId, psPath = cargoScreenPsPath})
  local fac = dGenerator.getFacilityById(locationId)
  if not fac then return end
  local spots = asProvider and fac.pickUpSpots or fac.dropOffSpots
  if not spots or not spots[1] then return end
  local toPos = dGenerator.getLocationCoordinates({type="facilityParkingspot", facId = fac.id, psPath=spots[1]:getPath()})
  if fromPos and toPos then
    freeroam_bigMapMode.setRoutePreviewSimple(fromPos, toPos)
  end
end
M.showLocationRoutePreview = showLocationRoutePreview

-- when a cargo list element ist clicked, set the bigMap route there
local function setCargoRoute(cargoId, origin)
  if cargoId == nil then
    return
  end
  local cargo = dParcelManager.getCargoById(cargoId)
  if not cargo then return end
  local toPos = dGenerator.getLocationCoordinates(origin and cargo.origin or cargo.destination)
  if toPos then
    freeroam_bigMapMode.setNavFocus(toPos)
  end
end

--by default, all cargo locations are active as bigMap markers. this function sets it so, that only the relevant markers are actually visible.
-- relevant markers include: destination of loaded and available cargo, vehicle offers
local tabNameToType = { vehicles = "vehicle", trailers = "trailer", parcels = "parcel", smallFluids="fluid", smallDryBulk="dryBulk", largeFluids="fluid", largeDryBulk="dryBulk" ,smallCement="cement", largeCement="cement", smallCash="cash", largeCash="cash"}
local function setVisibleIdsForBigMap()
  visibleBigMapIdsToCardIds = {}
  for cardId, card in pairs(cardsById) do
    --print("Card Id: " .. cardId)
    for bigMapId, _ in pairs(card.bigMapIds or {}) do
      --print("  -> " ..bigMapId)
      visibleBigMapIdsToCardIds[bigMapId] = visibleBigMapIdsToCardIds[bigMapId] or {cardIds = {}}
      visibleBigMapIdsToCardIds[bigMapId].cardIds[cardId] = true
    end
  end
end

M.showCargoRoutePreview = showCargoRoutePreview
M.showVehicleOfferRoutePreview = showVehicleOfferRoutePreview
M.highlightCargoInPoi = highlightCargoInPoi
M.setCargoRoute = setCargoRoute
M.setVisibleIdsForBigMap = setVisibleIdsForBigMap


-- other/utility functions
M.exitDeliveryMode = function() dGeneral.exitDeliveryMode() end
M.showCargoContainerHelpPopup = function()
  career_modules_tutorialPopups.introPopup("cargoContainerHowTo", true)
end
M.unloadCargoPopupClosed = function() dProgress.unloadCargoPopupClosed() end
M.requestDropOffData = function(...) dProgress.requestDropOffData(...) end
M.confirmDropOffData = function(...) dProgress.confirmDropOffData(...) end
M.clearTransientMoveForCargo = function(...) dParcelManager.clearTransientMoveForCargo(...) end

M.dropOffPopupClosed = function(mode)
  dProgress.dropOffPopupClosed(mode)
  if mode == "results" then
    extensions.hook("onDeliveryRewardsPopupClosed")
  end
  if mode == "cargoSelection" then
    extensions.hook("onDeliveryDropOffCargoSelectionPopupClosed")
  end
end

return M
