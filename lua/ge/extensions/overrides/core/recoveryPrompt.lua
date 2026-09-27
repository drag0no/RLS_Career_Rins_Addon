-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local active = false

local function slowerThan(v) local veh = getPlayerVehicle(0) if veh then return veh:getVelocity():len() <= v end return false end

local movingSlowlyThreshold = 10 -- m/s
local stoppedThreshold = 0.5 --m/s
local buttonOptions = {}

local function isOffroadRecoveryTarget(vehId)
  return gameplay_offroadRecovery
    and gameplay_offroadRecovery.isContractTarget
    and gameplay_offroadRecovery.isContractTarget(vehId) == true
end

-- --- Derby flip unstuck (disabled)
--[[
local demoDerbyUnstuckMaxSpeedKmh = 5
local demoDerbyUnstuckMaxSpeedMps = demoDerbyUnstuckMaxSpeedKmh / 3.6
local function canUseDemoDerbyUnstuck()
  return false, "Disabled"
end
]]

local function getTuningShopBusinessVehicleContext(vehId)
  if not (vehId and career_modules_business_businessInventory) then return nil, nil end
  local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(vehId)
  if not businessId or not vehicleId then return nil, nil end

  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId)
  if not vehicles then return businessId, nil end

  vehicleId = tonumber(vehicleId) or vehicleId
  for _, vehicle in ipairs(vehicles) do
    local storedId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if storedId == vehicleId then
      return businessId, vehicle
    end
  end

  return businessId, nil
end

local function getTowDestinationBusinessContext(vehId)
  local businessId, vehicle = getTuningShopBusinessVehicleContext(vehId)
  if not businessId or not vehicle then return nil, nil, nil end
  if career_modules_business_businessManager and career_modules_business_businessManager.getPurchasedBusinesses then
    local racingTeamBusinesses = career_modules_business_businessManager.getPurchasedBusinesses("racingTeam") or {}
    if racingTeamBusinesses[businessId] then
      return "racingTeam", businessId, vehicle
    end

    local tuningShopBusinesses = career_modules_business_businessManager.getPurchasedBusinesses("tuningShop") or {}
    if tuningShopBusinesses[businessId] then
      return "tuningShop", businessId, vehicle
    end
  end

  return nil, businessId, nil
end

local conditions = {
  outOfPursuit = function(type, vehId)
    if career_modules_playerDriving and career_modules_playerDriving.playerPursuitActive() then
      return false, "Disabled because of police chase."
    end
    return true
  end,
  vehicleSlow = function(type, vehId)
    local veh = scenetree.findObjectById(vehId)
    if veh then
      if veh:getVelocity():len() >= movingSlowlyThreshold then
        return false, "Stop your vehicle."
      end
    end
    return true
  end,
  vehicleStopped = function(type, vehId)
    local veh = scenetree.findObjectById(vehId)
    if veh then
      if veh:getVelocity():len() >= stoppedThreshold then
        return false, "Stop your vehicle completely."
      end
    end
    return true
  end,
  vehicleInInventory = function(type, vehId)
    if isOffroadRecoveryTarget(vehId) then
      return false, "Contract targets must be recovered manually."
    end
    if not (career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(vehId)) then
      return false, "This vehicle is not in your inventory."
    end
    return true
  end,
  vehicleOwned = function(type, vehId)
    if career_modules_inventory then
      local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
      if inventoryId then
        local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
        if vehInfo and vehInfo.owned then return true end
      end
    end
    return false, "You do not own this vehicle."
  end,
  favouriteSet = function(type, vehId)
    local favoriteVehicleId = career_modules_inventory.getFavoriteVehicle()
    if not favoriteVehicleId then return false, "No favourite vehicle set." end
    local vehInfo = career_modules_inventory.getVehicles()[favoriteVehicleId]
    if not vehInfo then return false, "No favourite vehicle set." end
    if vehInfo.timeToAccess
    or not career_modules_inventory.getVehicleIdFromInventoryId(favoriteVehicleId) and career_modules_insurance_insurance.inventoryVehNeedsRepair(favoriteVehicleId) -- vehicle is not spawned and needs a repair
    then
      return false, "Favourite vehicle still in repair."
    end
    return true
  end,
  notTestdriving = function(type, vehId)
    if career_modules_testDrive and career_modules_testDrive.isActive() then
      return false, "Disabled during test drive."
    end
    return true
  end,
  duringTestdrive = function(type, vehId)
    if career_modules_testDrive and career_modules_testDrive.isActive() then
      return true
    end
    return false
  end,
  towToRoadAllowedByPermission = function(type, vehId)
    if not career_modules_permissions then return true end
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
    local reason = career_modules_permissions.getStatusForTag("recoveryTowToGarage", {inventoryId = inventoryId})
    return reason.allow, reason.label
  end,
  vehicleIsDeliveryVehicle = function(type, vehId)
    if not career_modules_delivery_vehicleTasks then return false end
    if career_modules_delivery_vehicleTasks.isVehicleDeliveryVehicle(vehId) then
      return true
    end
    return false
  end,
  vehicleIsTuningShopJobVehicle = function(type, vehId)
    local _, businessId, vehicle = getTowDestinationBusinessContext(vehId)
    if not businessId or not vehicle then return false end
    return true
  end,
  tuningShopTowingUnlocked = function(type, vehId)
    if not career_modules_business_businessSkillTree then return false end
    local businessType, businessId = getTowDestinationBusinessContext(vehId)
    if not businessId then return false end
    if not businessType then return false end
    local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "towing") or 0
    if level == 0 then
      level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "qol", "towing") or 0
    end
    return level and level > 0
  end
}

local function getGlobalEconomyIndex()
  return career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
end

local flipUpRightCost = 50
local towToRoadCost = 75
local baseTowToGarageCost = 250

local function getPriceFunction(basePrice)
  return function()
    return {money = {amount = math.floor(basePrice * getGlobalEconomyIndex()), canBeNegative = true}}
  end
end

local function setupButtonOptions()
  buttonOptions = {
    -- available during regular career gameplay
    towToRoad = {
      label = _tr("ui.career.towToRoad"),
      type = "vehicle",
      includeConditions = {},
      enableConditions = {conditions.outOfPursuit, conditions.vehicleSlow, conditions.notTestdriving, conditions.vehicleInInventory},
      atFadeFunction = function(target)
        local veh = scenetree.findObjectById(target.vehId)
        if veh then
          spawn.teleportToLastRoad(veh, {resetVehicle = false})
          career_modules_payment.pay({money = {amount = math.floor(towToRoadCost * getGlobalEconomyIndex()), canBeNegative = true}}, {label = string.format("Towed your vehicle to the road")})
        end
      end,
      order = 5,
      startSlot = 7,
      active = true,
      enabled = true,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
      icon = "road",
      isRecoveryOption = true,
      confirmationText = "Do you want to tow your vehicle to the nearest road?",
      price = getPriceFunction(towToRoadCost)
    },
    flipUpright = {
      label = _tr("ui.radialmenu2.flipVehicleUpright"),
      type = "vehicle",
      includeConditions = {},
      enableConditions = {conditions.outOfPursuit, conditions.vehicleStopped, conditions.vehicleInInventory, conditions.notTestdriving},
      atFadeFunction = function(target)
        local veh = scenetree.findObjectById(target.vehId)
        if veh then
          spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, false )
          career_modules_payment.pay({money = {amount = math.floor(flipUpRightCost * getGlobalEconomyIndex()), canBeNegative = true}}, {label = string.format("Flipped your vehicle upright")})
        end
      end,
      order = 15,
      startSlot = 3,
      active = true,
      enabled = true,
      fadeActive = true,
      isRecoveryOption = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Flip",
      icon = "carToWheels",
      confirmationText = "Do you want your vehicle to be flipped upright?",
      price = getPriceFunction(flipUpRightCost)
    },
    getFavoriteVehicle = {
      type = "walk",
      label = _tr("ui.career.getFavoriteVehicle"),
      includeConditions = {},
      enableConditions = {conditions.outOfPursuit, conditions.favouriteSet, conditions.notTestdriving},
      atFadeFunction = function() career_modules_playerDriving.retrieveFavoriteVehicle() end,

      order = 11,
      active = false,
      enabled = true,
      fadeActive = true,
      icon = "carStarred",
      confirmationText = "Do you want to retrieve your favorite vehicle?",
      price = function()
        return career_modules_playerDriving.getFavoriteVehicleRetrievalPrice()
      end
    },
    -- only during mission
    flipMission = {
      type = "vehicle",
      label = _tr("ui.radialmenu2.flipVehicleUpright"),
      --includeCondition = function() return gameplay_missions_missionManager.getForegroundMissionId() ~= nil end,
      includeConditions = {},
      enableConditions = {conditions.vehicleStopped},
      atFadeFunction = nop,
      order = 5,
      startSlot = 3,
      active = false,
      enabled = true,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Flip",
      icon = "carToWheels"
    },
    recoverMission = {
      type = "vehicle",
      label = _tr("ui.radialmenu2.recoverToLastRoad"),
      includeConditions = {},
      enableConditions = {conditions.vehicleSlow},
      atFadeFunction = nop,
      order = 7,
      startSlot = 7,
      active = false,
      enabled = true,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
      icon = "car"
    },
    submitMission = {
      type = "none",
      label = _tr("missions.missions.recoveryPrompt.submitScore"),
      includeConditions = {},
      enableConditions = {},
      atFadeFunction = nop,
      order = 10,
      startSlot = 5,
      active = false,
      enabled = true,
      fadeActive = false,
      icon = "checkboxOn"
    },
    restartMission = {
      type = "none",
      label = _tr("missions.missions.recoveryPrompt.restartMission"),
      includeConditions = {},
      enableConditions = {},
      atFadeFunction = nop,
      order = 15,
      startSlot = 1,
      active = false,
      enabled = true,
      fadeActive = false,
      icon = "restart"
    },
    -- only during tutorial
    repairHere = {
      type = "vehicle",
      label = _tr("ui.mission.panel.repair"),
      --veh, pos, rot, checkOnlyStatics_, visibilityPoint_, removeTraffic_, centeredPosition, resetVehicle
      atFadeFunction = function()
        local veh = getPlayerVehicle(0)
        if veh then
          if career_career.isActive() then
            if career_modules_inventory.getCurrentVehicle() then
              career_modules_inventory.updatePartConditions(nil, career_modules_inventory.getCurrentVehicle(), function() career_modules_insurance_insurance.startRepair(nil, nil, function() extensions.hook("onRecoveryPromptRepairHereUsed") end) end)
              return
            end
          end
          spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true )
          extensions.hook("onRecoveryPromptRepairHereUsed")
        end
      end,
      includeConditions = {},
      enableConditions = {conditions.vehicleSlow, function(_, vehId)
        if isOffroadRecoveryTarget(vehId) then
          return false, "Contract targets cannot be repaired during recovery."
        end
        return true
      end},
      order = 10,
      active = true,
      isRecoveryOption = true,
      enabled = true,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
      icon = "wrench"
    },
    -- testing for non-career freeroam
    resetVehicle = {
      type = "vehicle",
      label = _tr("ui.common.resetVehicle"),
      includeConditions = {},
      enableConditions = {},
      atFadeFunction = function() be:resetVehicle(0) end,
      order = 20,
      active = false,
      enabled = true,
      fadeActive = true
    },
    -- during testdrive
    stopTestdrive = {
      type = "none",
      label = _tr("ui.career.testDrive.stopTestDrive"),
      --veh, pos, rot, checkOnlyStatics_, visibilityPoint_, removeTraffic_, centeredPosition, resetVehicle
      atFadeFunction = function()
        career_modules_testDrive.stop(true)
      end,
      includeConditions = {conditions.duringTestdrive},
      enableConditions = {},
      order = 10,
      active = true,
      enabled = true,
      fadeActive = true,
      icon = "restart"
    },
      -- during testdrive
    giveBackDeliveryVehicle = {
      type = "vehicle",
      label = "Discard Delivery Vehicle",
      --veh, pos, rot, checkOnlyStatics_, visibilityPoint_, removeTraffic_, centeredPosition, resetVehicle
      atFadeFunction = function(target)
        career_modules_delivery_vehicleTasks.giveBackDeliveryVehicle(target.vehId)
      end,
      includeConditions = {conditions.outOfPursuit, conditions.vehicleIsDeliveryVehicle},
      enableConditions = {conditions.vehicleSlow},
      order = 10,
      active = true,
      enabled = true,
      fadeActive = true,
      icon = "restart"
    },
    returnLoanedVehicle = {
      label = "Return loaned vehicle",
      type = "vehicle",
      includeConditions = {function(_, vehId) return conditions.vehicleInInventory(_, vehId) and not conditions.vehicleOwned(_, vehId) end},
      enableConditions = {conditions.outOfPursuit, conditions.vehicleStopped, conditions.notTestdriving},
      atFadeFunction = function(target)
        if career_modules_inventory then
          local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(target.vehId)
          if inventoryId then
            career_modules_loanerVehicles.returnVehicle(inventoryId)
          end
        end
      end,
      order = 5,
      active = true,
      enabled = true,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
      icon = "car",
      confirmationText = "Do you want to return this loaned vehicle?"
    },
    towToTuningShop = {
      label = function(options, target)
        local businessType, businessId = getTowDestinationBusinessContext(target.vehId)
        if businessType and businessId and freeroam_facilities then
          local facility = freeroam_facilities.getFacility(businessType, businessId)
          if facility and facility.name then
            local localizedName = translateLanguage and translateLanguage(facility.name, facility.name, true) or facility.name
            return string.format("Tow to %s", localizedName)
          end
          if businessType == "racingTeam" then
            return "Tow to Racing Team"
          end
        end
        return "Tow to Tuning Shop"
      end,
      type = "vehicle",
      includeConditions = {conditions.vehicleIsTuningShopJobVehicle, conditions.tuningShopTowingUnlocked},
      enableConditions = {conditions.outOfPursuit, conditions.vehicleSlow, conditions.notTestdriving},
      atFadeFunction = function(target)
        local businessType, businessId, vehicle = getTowDestinationBusinessContext(target.vehId)
        if not (businessType and businessId and vehicle and career_modules_business_businessInventory) then return end
        local veh = scenetree.findObjectById(target.vehId)
        if veh then
          career_modules_business_businessInventory.teleportToBusinessGarage(businessType, businessId, veh, true)
        end
      end,
      order = 12,
      startSlot = 7,
      active = true,
      enabled = true,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
      icon = "tow",
      confirmationText = "Do you want to tow this vehicle back to the business facility?",
      menuTag = "towing",
      path = "towing/",
      message = "ui.career.towed"
    }
  }
end

local function updateTuningShopTowButton(newVehId)
  if not buttonOptions.towToTuningShop then return end
  local vehId = newVehId or (be and be:getPlayerVehicleID(0))
  local businessType, businessId, vehicle = getTowDestinationBusinessContext(vehId)
  local activeState = false
  if businessType and businessId and vehicle and career_modules_business_businessSkillTree then
    local level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "shop-upgrades", "towing") or 0
    if level == 0 then
      level = career_modules_business_businessSkillTree.getNodeProgress(businessId, "qol", "towing") or 0
    end
    activeState = level and level > 0
  end
  buttonOptions.towToTuningShop.active = activeState and true or false
end

local function clearDynamicGarageButtons(prefix, keepIds)
  local toRemove = {}
  for id in pairs(buttonOptions) do
    if type(id) == "string" and id:sub(1, #prefix) == prefix and not (keepIds and keepIds[id]) then
      table.insert(toRemove, id)
    end
  end
  for _, id in ipairs(toRemove) do
    buttonOptions[id] = nil
  end
end

local function addTowingButtons()
  if not getCurrentLevelIdentifier() then return end
  -- Drop sold/unowned garage tow targets left behind from earlier ownership.
  clearDynamicGarageButtons("towTo", { towToRoad = true, towToTuningShop = true })
  local garages = freeroam_facilities.getFacilitiesByType("garage")
  local discoveredGarages = 0

  for _, garage in ipairs(garages) do
    if not garage.noQuickTravel then
      local function getPrice(target)
        if career_modules_insurance_insurance.isRoadSideAssistanceFree(career_modules_inventory.getInventoryIdFromVehicleId(target.vehId)) then
          return {}
        end
        local price = career_modules_quickTravel.getPriceForQuickTravelToGarage(garage)
        price = math.max(0, tonumber(price) or 0) +
          math.floor(baseTowToGarageCost * getGlobalEconomyIndex() * 100 + 0.5) / 100
        return {money = {amount = price, canBeNegative = true}}
      end

      if career_modules_garageManager and career_modules_garageManager.isAccessibleGarage(garage.id) then
        discoveredGarages = discoveredGarages + 1
        buttonOptions[string.format("towTo%s", garage.id)] =
        {
          type = "vehicle",
          label = function(options, target)
            return string.format("%s", _tr(garage.name))
          end,
          includeConditions = {},
          menuTag = "towing",
          enableConditions = {conditions.outOfPursuit, conditions.vehicleSlow, conditions.vehicleInInventory, conditions.notTestdriving, conditions.towToRoadAllowedByPermission},
          atFadeFunction = function(target)
            career_modules_playerDriving.teleportToGarage(garage.id, scenetree.findObjectById(target.vehId), false)

            local invVehId = career_modules_inventory.getInventoryIdFromVehicleId(target.vehId)
            local coveredByInsurance = career_modules_insurance_insurance.isRoadSideAssistanceFree(invVehId)
            if coveredByInsurance then
              career_modules_insurance_insurance.useRoadsideAssistance(invVehId)
            else
              local price = getPrice(target)
              career_modules_payment.pay(price, {label = string.format("Towed your vehicle to your garage")})
            end
          end,
          message = _tr("ui.career.towed"),
          order = discoveredGarages,
          active = true,
          enabled = true,
          fadeActive = true,
          fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
          icon = "garageNumber"..discoveredGarages,
          price = getPrice,
          confirmationText = "Do you want to tow your vehicle to this garage?",
          path = "towing/",
          noUniqueID = true,
        }
      end
    end
  end
end

local function getRacingTeamQuickTravelButton(order)
  if not career_modules_business_businessManager or not career_modules_business_businessSkillTree then return end

  local purchased = career_modules_business_businessManager.getPurchasedBusinesses("racingTeam")
  local rtId = purchased and next(purchased)
  if not rtId then return end

  local skillUnlock = career_modules_business_businessSkillTree.getNodeProgress(rtId, "qol", "quick-travel")
  if (skillUnlock or 0) <= 0 then return end

  local pos, rot = career_modules_business_businessInventory.getBusinessGaragePosRot("racingTeam", rtId, nil, 1)
  if not pos then return end

  return string.format("quickTravelTo%s", rtId), {
    type = "walk",
    label = "Belasco Racing Team",
    includeConditions = {},
    menuTag = "quickTravel",
    enableConditions = {},
    atFadeFunction = function() career_modules_quickTravel.quickTravelToPos(pos, true, "ui.career.attributeLog.quickTravelGarageTaxi", rot) end,
    order = order,
    active = true,
    enabled = true,
    fadeActive = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "garageNumber" .. math.min(10, order),
    price = function() return { money = { amount = career_modules_quickTravel.getPriceForQuickTravel(pos) } } end,
    confirmationText = "Do you want to quick travel to the racing team?",
    path = "quickTravel/",
    noUniqueID = true,
  }
end

local function addQuickTravelButtons()
  if not getCurrentLevelIdentifier() then return end
  -- Drop sold/unowned garage travel targets left behind from earlier ownership.
  clearDynamicGarageButtons("quickTravelTo", { quickTravelToVehicle = true })
  local garages = freeroam_facilities.getFacilitiesByType("garage")
  local discoveredGarages = 0

  for _, garage in ipairs(garages) do
    if not garage.noQuickTravel then
      if career_modules_garageManager and career_modules_garageManager.isAccessibleGarage(garage.id) then
        discoveredGarages = discoveredGarages + 1
        buttonOptions[string.format("quickTravelTo%s", garage.id)] =
        {
          type = "walk",
          label = function(options)
            return string.format("%s", _tr(garage.name))
          end,
          includeConditions = {},
          menuTag = "quickTravel",
          enableConditions = {},
          atFadeFunction = function()
            career_modules_quickTravel.quickTravelToGarage(garage)
          end,
          order = discoveredGarages,
          active = true,
          enabled = true,
          fadeActive = true,
          fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
          icon = "garageNumber"..discoveredGarages,
          price = function() return {money = {amount = career_modules_quickTravel.getPriceForQuickTravelToGarage(garage)}} end,
          confirmationText = "Do you want to quick travel?",
          path = "quickTravel/",
          noUniqueID = true,
        }
      end
    end
  end

  local rtKey, rtButton = getRacingTeamQuickTravelButton(discoveredGarages + 1)
  if rtKey then
    discoveredGarages = discoveredGarages + 1
    buttonOptions[rtKey] = rtButton
  end

  local function getPrice()
    local lastVehicleId = career_modules_inventory.getLastVehicle()
    local vehObjId = career_modules_inventory.getVehicleIdFromInventoryId(lastVehicleId)
    if vehObjId then
      local vehObj = getObjectByID(vehObjId)
      local pos = vehObj:getPosition()
      local price = career_modules_quickTravel.getPriceForQuickTravel(pos)
      return {money = {amount = price}}
    end
    return {}
  end

  buttonOptions.quickTravelToVehicle =
    {
      type = "walk",
      label = function(options)
        return "Your last vehicle"
      end,
      includeConditions = {},
      menuTag = "quickTravel",
      enableConditions = {},
      atFadeFunction = function()
        local lastVehicleId = career_modules_inventory.getLastVehicle()
        local vehObjId = career_modules_inventory.getVehicleIdFromInventoryId(lastVehicleId)
        if vehObjId then
          local vehObj = getObjectByID(vehObjId)
          local pos = vehObj:getPosition()
          career_modules_quickTravel.quickTravelToPos(pos, true, "Quick traveled to your vehicle")
        end
      end,
      order = 25,
      active = true,
      enabled = function()
        local lastVehicleId = career_modules_inventory.getLastVehicle()
        return career_modules_inventory.getVehicleIdFromInventoryId(lastVehicleId)
      end,
      fadeActive = true,
      fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
      icon = "car",
      price = getPrice,
      confirmationText = "Do you want to quick travel?",
      path = "quickTravel/",
      noUniqueID = true,
    }

  buttonOptions.callTaxi = {
    type = "walk",
    label = function(options)
      return "Call a taxi"
    end,
    order = 100,
    menuTag = "quickTravel",
    -- Vanilla taxi meters the fare; no upfront charge (same as marketplace hail).
    atFadeFunction = function()
      local ready = career_modules_playerDriving and career_modules_playerDriving.ensureVanillaTaxiReady
          and career_modules_playerDriving.ensureVanillaTaxiReady()
      if not ready and extensions and extensions.load then
        pcall(extensions.load, "gameplay_taxi")
        ready = career_modules_playerDriving and career_modules_playerDriving.ensureVanillaTaxiReady
          and career_modules_playerDriving.ensureVanillaTaxiReady()
      end
      if ready and gameplay_taxi and gameplay_taxi.callForTaxi then
        gameplay_taxi.callForTaxi()
      else
        ui_message("Taxi service is currently unavailable.", 5, "taxi", "warning")
      end
    end,
    active = true,
    enabled = true,
    fadeStartSound = "event:>UI>Missions>Vehicle_Recover",
    icon = "car",
    fadeActive = false,
    confirmationText = "Do you want to call a taxi?",
    path = "quickTravel/",
    noUniqueID = true,
  }
end

local function isActive() return active end
local function setActive(a) active = a end
local function setDefaultsForFreeroam()
  active = false
  for _, o in pairs(buttonOptions) do o.active = false end
  updateTuningShopTowButton()
end

local function setDefaultsForCareer()
  active = true
  for _, o in pairs(buttonOptions) do o.active = false end
  buttonOptions.towToRoad.active = true
  buttonOptions.flipUpright.active = true

  buttonOptions.getFavoriteVehicle.active = true
  buttonOptions.stopTestdrive.active = true
  buttonOptions.giveBackDeliveryVehicle.active = true
  buttonOptions.returnLoanedVehicle.active = true
  addTowingButtons()
  addQuickTravelButtons()
  updateTuningShopTowButton()
end

local function setDefaultsForTutorial()
  active = true
  for _, o in pairs(buttonOptions) do o.active = false end
  buttonOptions.towToRoad.active = true
  buttonOptions.repairHere.active = true
  buttonOptions.flipUpright.active = true
  buttonOptions.getFavoriteVehicle.active = false
end

local function setEverythingActive()
  active = true
  for _, o in pairs(buttonOptions) do o.active = true end
end

local function deactivateAllButtons() for _, o in pairs(buttonOptions) do o.active = false end end

local function setButtonActiveById(id, a)
  if not buttonOptions[id] then log("W","","Tried to set active for button, but the id couldnt be found: " .. dumps(id)) return end
  buttonOptions[id].active = a
end

local function getButtonActiveById(id)
  if not buttonOptions[id] then log("W","","Tried to get enable for button, but the id couldnt be found: " .. dumps(id)) return end
  return buttonOptions[id].active
end

local function setButtonEnabledById(id, e)
  if not buttonOptions[id] then log("W","","Tried to set enable for button, but the id couldnt be found: " .. dumps(id)) return end
  buttonOptions[id].enabled = e
  if e then
    buttonOptions[id].active = e
  end
end

local function highestOrderPlusOne()
  local highest = 0
  for _, o in pairs(buttonOptions) do
    highest = math.max(highest, o.order)
  end
  return highest + 1
end

local function addButton(id, label, atFadeFunction, order, message, active, enabled, fadeActive, icon, additionalOptions)
  local options = {}

  if type(id) == "table" then
    options = id
    id = options.id
  else
    options.id = id
    options.label = label
    options.atFadeFunction = atFadeFunction
    options.order = order
    options.message = message
    options.active = active
    options.enabled = enabled
    options.fadeActive = fadeActive
    options.icon = icon
    if additionalOptions then
      for k, v in pairs(additionalOptions) do
        options[k] = v
      end
    end
  end

  if not id then log("E","","Tried creating button without ID!" ) return end
  if buttonOptions[id] and not buttonOptions[id].customButton then log("E","Tried to add a button, but it already exists and it's not a custom button, so it's not allowed! " .. dumps(id)) return end

  local activeValue = options.active
  local fadeActiveValue = options.fadeActive
  if activeValue == nil then activeValue = true end
  if fadeActiveValue == nil then fadeActiveValue = true end

  local btn = {
    label = options.label or "No Label!",
    type = options.type or "vehicle",
    includeConditions = options.includeConditions or {},
    enableConditions = options.enableConditions or {},
    atFadeFunction = options.atFadeFunction or function() log("E","","No Function set for " .. dumps(id) ) end,
    order = options.order or highestOrderPlusOne(),
    startSlot = options.startSlot,
    active = activeValue,
    enabled = options.enabled,
    fadeActive = fadeActiveValue,
    fadeStartSound = options.fadeStartSound,
    icon = options.icon,
    confirmationText = options.confirmationText,
    price = options.price,
    message = options.message,
    menuTag = options.menuTag,
    path = options.path,
    noUniqueID = options.noUniqueID,
    keepMenuOpen = options.keepMenuOpen,
    limit = options.limit,
    count = options.count or 0,
    customButton = true,
    uniqueID = options.uniqueID or id,
  }
  if buttonOptions[id] then
    log("E","","Button for Id already exists and will be overwritten: " .. dumps(id) .. ": " .. dumps(buttonOptions[btn.id]))
  end
  buttonOptions[id] = btn
  local orders = {}
  for _, o in pairs(buttonOptions) do
    if orders[o.order] then log("E","Order Collision for buttons: " .. orders[o.order] .. "/"..o.id) end
    orders[o.order] = o.id
  end
end

local function removeButtonById(id)
  if not buttonOptions[id] then log("W","","Tried removing button, but it doesnt exist: " .. dumps(id)) return end
  if not buttonOptions[id].customButton then log("E","Tried to remove a button, but it's not a custom button, so it's not allowed! " .. dumps(id)) return end
  buttonOptions[id] = nil
end

M.isActive = isActive
M.setActive = setActive
M.setDefaultsForFreeroam = setDefaultsForFreeroam
M.setDefaultsForCareer = setDefaultsForCareer
M.setDefaultsForTutorial = setDefaultsForTutorial
M.setEverythingActive = setEverythingActive
M.deactivateAllButtons = deactivateAllButtons
M.addButton = addButton
M.removeButtonById = removeButtonById
M.getButtonActiveById = getButtonActiveById
M.setButtonActiveById = setButtonActiveById
M.setButtonEnabledById = setButtonEnabledById


-- counter utility

local function setButtonLimits(limits)
  for _, o in pairs(buttonOptions) do o.limit = nil end
  for id, limit in pairs(limits or {}) do
    if limit == -1 then
      buttonOptions[id].limit = nil
    else
      buttonOptions[id].limit = limit
    end
  end
end

local function resetButtonLimitCounters(onlyFor)
  for id, o in pairs(buttonOptions) do
    if not onlyFor or onlyFor[id] then
      o.count = 0
    end
  end
end

local function getButtonLimitsAndCounts()
  local ret = {}
  for id, o in pairs(buttonOptions) do
    ret[id] = {limit = o.limit, count = o.count}
  end
  return ret
end

M.setButtonLimits = setButtonLimits
M.resetButtonLimitCounters = resetButtonLimitCounters
M.getButtonLimitsAndCounts = getButtonLimitsAndCounts

-- serialization
local function serializeState()
  local ret = {
    active = active,
    buttons = {}
  }
  for id, btn in pairs(buttonOptions) do
    ret.buttons[id] = btn.active or false
  end
  return ret
end
local function deserializeState(data)
  active = data.active
  for id, btnActive in pairs(data.buttons or {}) do
    setButtonActiveById(id, btnActive)
  end
end
M.serializeState = serializeState
M.deserializeState = deserializeState

-- this is the actual recovery process. create a snapshot before the fadeing starts
local currentRecoveryOptionId = nil
local currentRecoveryOptionTarget = nil
local fadeDuration = 0.3
local function buttonPressed(buttonId, target)
  if career_career and career_career.isActive() and not gameplay_walk.isWalking() and not gameplay_missions_missionManager.getForegroundMissionId() then
    core_vehicleBridge.executeAction(getPlayerVehicle(0), 'createPartConditionSnapshot', "beforeTeleport")
    core_vehicleBridge.executeAction(getPlayerVehicle(0), 'setPartConditionResetSnapshotKey', "beforeTeleport")
  end

  currentRecoveryOptionId = buttonId
  currentRecoveryOptionTarget = target
  if buttonOptions[buttonId].fadeActive then
    core_vehicleBridge.requestValue(getPlayerVehicle(0), function()
      if buttonOptions[buttonId].fadeStartSound then
        Engine.Audio.playOnce('AudioGui',buttonOptions[buttonId].fadeStartSound)
      end
      ui_fadeScreen.start(fadeDuration)
    end , 'ping')
  else
    M.handleCurrRecoveryOption()
  end
end

local popupData
local function onPopupClosed()
  currentRecoveryOptionId = nil
  popupData = nil
  --simTimeAuthority.pause(false)
end

local function handleCurrRecoveryOption()
  if not currentRecoveryOptionId then return end
  local option = buttonOptions[currentRecoveryOptionId]
  extensions.hook("onRecoveryPromptButtonPressed", currentRecoveryOptionId)
  if option then
    option.atFadeFunction(currentRecoveryOptionTarget)
    if option.count then
      option.count = option.count + 1
    end
    if option.message then
      ui_message(option.message, 5, "recoveryPromptMessage")
    end
  else
    log("E","","Couldnt use recovery option. none was found for ID " .. currentRecoveryOptionId)
  end

  if option.fadeActive then
    ui_fadeScreen.stop(fadeDuration)
    ui_router.reload()
  end

  currentRecoveryOptionId = nil
  currentRecoveryOptionTarget = nil
  if not option.keepMenuOpen then
    onPopupClosed()
  end
  gameplay_markerInteraction.setForceReevaluateOpenPrompt()
    --extensions.hook("onCareerCustomTowHook")
end

local function onScreenFadeState(state)
  -- only proceed if we actually have a recovery request.
  handleCurrRecoveryOption()
end

local function getRecoveryTargets()
  if not gameplay_walk.isWalking() then
    return {{type = "vehicle", vehId = be:getPlayerVehicleID(0)}}
  end
  local vehInFront = gameplay_walk.getVehicleInFront()
  if vehInFront then
    return {
      {type = "vehicle", vehId = vehInFront:getId()},
      {type = "walk"}
    }
  else
    return {{type = "walk"}}
  end
end

local function sortByOrder(a,b) return a.order < b.order end
local function getButtonsForTarget(target)
  local buttons = {}
  for id, option in pairs(buttonOptions) do
    if (option.type or "none") == target.type and option.active then
      local add = true
      for key, cond in ipairs(option.includeConditions or {}) do
        add = cond(target.type, target.vehId)
      end
      if add then
        local enabled = type(option.enabled) == "function" and option.enabled(option, target) or option.enabled
        local reason = nil
        for key, cond in ipairs(option.enableConditions or {}) do
          local en, rs = cond(target.type, target.vehId)
          enabled = en and enabled
          reason = reason or rs
        end
        local label = type(option.label) == "function" and option.label(option, target) or option.label
        if option.limit then
          label = {txt = 'missions.missions.recoveryPrompt.remainingUses', context = {label = label, count = option.limit - option.count}}
          enabled = enabled and option.count < option.limit
        end

        local price = nil
        if career_career.isActive() then
          price =  type(option.price) == "function" and option.price(target) or option.price
        end
        if price and career_modules_payment and not career_modules_payment.canPay(price) then
          enabled = false
          reason = "Insufficient funds"
        end
        local disableReason = reason or (not enabled and "Disabled")
        local uniqueID = "recovery_"..id .."_".. dumps(target)
        local btn = {
          id = id,
          targetType = target.type,
          targetVehId = target.vehId,
          label = label,
          luaCallback = function() core_recoveryPrompt.buttonPressed(id, target) end,
          order = option.order,
          startSlot = option.startSlot or 1,
          keepMenuOpen = option.keepMenuOpen,
          price = price,
          enabled = enabled,
          disableReason = disableReason,
          soundClass = (option.fadeStartSound and "bng_click_empty" or nil),
          icon = option.icon,
          confirmationText = option.confirmationText,
          ["goto"] = option["goto"],
          path = option.path,
          uniqueID = uniqueID,
        }
        if option.noUniqueID then
          btn.uniqueID = nil
        end
        table.insert(buttons, btn)
      end
    end
  end
  table.sort(buttons, sortByOrder)
  return buttons
end

local function getDemoDerbyController()
  local derby = rawget(_G, "gameplay_events_freeroam_demolitionDerby")
  if type(derby) ~= "table" then
    return nil
  end
  return derby
end

local function isDemoDerbyRecoveryOverrideActive()
  local derby = getDemoDerbyController()
  if not derby or type(derby.isRecoveryRadialOverrideActive) ~= "function" then
    return false
  end
  local ok, activeState = pcall(derby.isRecoveryRadialOverrideActive)
  return ok and activeState == true
end

local function createPopupData()
  if not active then popupData = nil return false end

  if isDemoDerbyRecoveryOverrideActive() then
    return false
  end

  local buttons = {}
  local targets = getRecoveryTargets()
  for i, target in ipairs(targets) do
    for _, btn in ipairs(getButtonsForTarget(target)) do
      table.insert(buttons, btn)
    end
  end
  for _, btn in ipairs(getButtonsForTarget({type="none"})) do
    table.insert(buttons, btn)
  end
  if not next(buttons) then
    log("W","","Tried to open recovery prompt, but no buttons were active. Not opening prompt.")
    return false
  end

  if next(buttons) then
    buttons[1].default = true
  end

  -- TODO in the future the file could probably be refactored so we dont need popupData at all anymore, but for now it works
  popupData = {title = title or "Recovery Menu", buttons = buttons}
  return true
end

local missionPauseActionIds = {
  restartMission = true,
  flipMission = true,
  recoverMission = true,
  towToRoad = true,
}

local careerPauseActionIds = {
  flipUpright = true,
  towToRoad = true,
}

local function makePauseRightRailButton(button)
  return {
    id = button.id,
    title = button.label,
    icon = button.icon,
    holdToClick = button.confirmationText,
    enabled = button.enabled,
    disableReason = button.disableReason,
    order = button.order,
    startSlot = button.startSlot,
    targetType = button.targetType,
    targetVehId = button.targetVehId,
  }
end

local function getPauseMissionRightRailButtons()
  local buttons = {}
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil

  if playerVehId and playerVehId >= 0 then
    for _, button in ipairs(getButtonsForTarget({type = "vehicle", vehId = playerVehId})) do
      if missionPauseActionIds[button.id] then
        table.insert(buttons, makePauseRightRailButton(button))
      end
    end
  end

  for _, button in ipairs(getButtonsForTarget({type = "none"})) do
    if missionPauseActionIds[button.id] then
      table.insert(buttons, makePauseRightRailButton(button))
    end
  end

  table.sort(buttons, sortByOrder)
  return buttons
end

local function getPauseCareerRightRailButtons()
  local buttons = {}
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil

  if playerVehId and playerVehId >= 0 then
    for _, button in ipairs(getButtonsForTarget({type = "vehicle", vehId = playerVehId})) do
      if careerPauseActionIds[button.id] then
        table.insert(buttons, makePauseRightRailButton(button))
      end
    end
  end

  table.sort(buttons, sortByOrder)
  return buttons
end

local function onResetGameplay(playerID)
  if active then
    local root = "/root/sandbox/quick/"
    if career_career.isActive() then
      root = "/root/sandbox/career/"
    end
    if gameplay_missions_missionManager.getForegroundMissionId() then
      root = "/root/sandbox/mission/"
    end
    core_quickAccess.setEnabled(true, root)
  end
end

local function addButtonsForLevel(level)
  for _, context in ipairs({
    {
      root = "/root/sandbox/career/",
      enabled = function() return career_career.isActive() and not gameplay_missions_missionManager.getForegroundMissionId() end,
    },
    {
      root = "/root/sandbox/mission/",
      enabled = function() return gameplay_missions_missionManager.getForegroundMissionId() end,
    }
  }) do
    local root = context.root
    core_quickAccess.addEntry(
      {
        level = root .. (level or ""),
        generator = function(entries)
          if not context.enabled() then return end
          if level and isDemoDerbyRecoveryOverrideActive() then return end
          createPopupData()
          if not popupData then return end
          for _, button in ipairs(popupData.buttons or {}) do
            if button.path == level then
              local entry = {
                title = button.label,
                icon = button.icon,
                priority = 90,
                holdToClick = button.confirmationText,
                price = button.price,
                enabled = button.enabled,
                startSlot = button.startSlot,
                ["goto"] = button["goto"],
                disableReason = button.disableReason,
                uniqueID = button.uniqueID,
                ignoreAsRecentActionForCategory = "sandbox",
                onSelect = function()
                  button.luaCallback()
                  return button.keepMenuOpen and {"reload"} or {"hide"}
                end
              }
              table.insert(entries, entry)
            end
          end
        end
      }
    )

    if level then
      local name, icon = nil, nil
      if level == "quickTravel/" then
        name = "Quick Travel"
        icon = "fastTravel"
      end
      if level == "towing/" then
        name = "Towing"
        icon = "tow"
      end
      core_quickAccess.addEntry({
        level = root,
        uniqueID = name .. "unique",
        generator = function(entries)
          if isDemoDerbyRecoveryOverrideActive() then return end
          table.insert(entries, {
            title = name,
            icon = icon,
            ["goto"] = root .. level,
            uniqueID = name .. "unique"
          })
        end
      })
    end
  end
end

local function onExtensionLoaded()
  setupButtonOptions()
end

local quickAccessInitialized
local function onBeforeRadialOpened()
  if quickAccessInitialized then return end
  quickAccessInitialized = true
  if not next(buttonOptions) then setupButtonOptions() end
  addButtonsForLevel(nil)
  addButtonsForLevel("quickTravel/")
  addButtonsForLevel("towing/")
end

local function onHideRadialMenu()
  popupData = nil
end

local function onQuickAccessLoaded()
  quickAccessInitialized = nil
end

-- returns a sanitized list of the custom recovery options, whether they are active or not
local function getCustomRecoveryOptionsActiveState()
  local recoveryOptions = {}
  for recoveryOptionId, recoveryOptionData in pairs(buttonOptions) do
    recoveryOptions[recoveryOptionId] = {
      active = recoveryOptionData.active,
      enabled = recoveryOptionData.enabled,
      label = recoveryOptionData.label,
      icon = recoveryOptionData.icon,
      isRecoveryOption = recoveryOptionData.isRecoveryOption,
    }
  end
  return recoveryOptions
end

local function onVehicleSwitched(oldId, newId, player)
  updateTuningShopTowButton(newId)
end

M.addTowingButtons = addTowingButtons
M.addTaxiButtons = addQuickTravelButtons
M.buttonPressed = buttonPressed
M.onPopupClosed = onPopupClosed
M.onResetGameplay = onResetGameplay
M.onScreenFadeState = onScreenFadeState
M.handleCurrRecoveryOption = handleCurrRecoveryOption
--M.uiPopupButtonPressed = uiPopupButtonPressed
--M.uiPopupCancelPressed = uiPopupCancelPressed
M.getCustomRecoveryOptionsActiveState = getCustomRecoveryOptionsActiveState
M.getPauseMissionRightRailButtons = getPauseMissionRightRailButtons
M.getPauseCareerRightRailButtons = getPauseCareerRightRailButtons

--M.onCareerActive = onCareerActive
M.onExtensionLoaded = onExtensionLoaded
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onHideRadialMenu = onHideRadialMenu
M.onQuickAccessLoaded = onQuickAccessLoaded
M.onVehicleSwitched = onVehicleSwitched

return M
