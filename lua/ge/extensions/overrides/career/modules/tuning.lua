-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career", "gameplay_achievement"}

local inventoryId
local vehicleVarsBefore
local changedVars
local shoppingCart

local originComputerId

local tether
local switchingVehicle = false
local returnRoute = nil

local prices = {
  Suspension = {
    Front = {
      price = 100
    },
    Rear = {
      price = 100
    }
  },

  Wheels = {
    Front = {
      price = 100
    },
    Rear = {
      price = 100
    }
  },

  Transmission = {
    price = 500,
    default = {
      default = true,
      variables = {
        ["$gear_1"] = { price = 100},
        ["$gear_2"] = { price = 100},
        ["$gear_3"] = { price = 100},
        ["$gear_4"] = { price = 100},
        ["$gear_5"] = { price = 100},
        ["$gear_6"] = { price = 100},
        ["$gear_R"] = { price = 100},
      }
    }
  },

  ["Wheel Alignment"] = {
    Front = {
      price = 100
    },
    Rear = {
      price = 100
    }
  },

  Chassis = {
    price = 100
  },

  default = {
    default = true,
    price = 200
  }
}

local shoppingCartBlackList = {
  {name = "$$ffbstrength", category = "Chassis"},
  {name = "$tirepressure_F", category = "Wheels", subCategory = "Front"},
  {name = "$tirepressure_R", category = "Wheels", subCategory = "Rear"},
}

local function isOnBlackList(varData)
  for _, blackListItem in ipairs(shoppingCartBlackList) do
    if blackListItem.name ~= varData.name then goto continue end
    if blackListItem.category ~= varData.category then goto continue end
    if blackListItem.subCategory ~= varData.subCategory then goto continue end
    do return true end
    ::continue::
  end
  return false
end

local function getPrice(category, subCategory, varName)
  if prices[category] then
    if prices[category][subCategory] then
      if prices[category][subCategory].variables and prices[category][subCategory].variables[varName] then
        return prices[category][subCategory].variables[varName].price or 0
      end
    elseif prices[category].default then
      if prices[category].default.variables and prices[category].default.variables[varName] then
        return prices[category].default.variables[varName].price or 0
      end
    end
  elseif prices.default then
    if prices.default.variables and prices.default.variables[varName] then
      return prices.default.variables[varName].price or 0
    end
  end
  return 0
end

local function getPriceCategory(category)
  if prices[category] then return prices[category].price or 0 end
  return prices.default.price
end

local function getPriceSubCategory(category, subCategory)
  if prices[category] then
    if prices[category][subCategory] then
      return prices[category][subCategory].price or 0
    end
    return prices[category].default and prices[category].default.price or 0
  end
  return 0
end

local function setupTether()
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = vehId and getObjectByID(vehId) or nil
  local computer = originComputerId and freeroam_facilities.getFacility("computer", originComputerId) or nil
  if not veh or not computer then return false end

  -- calculate the size of the vehicle to use for tethering
  local oobb = veh:getSpawnWorldOOBB()
  local vehCenter = oobb:getCenter()
  local vehRadius = (oobb:getPoint(0) - oobb:getPoint(6)):length()
  -- calculate computer position
  local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(computer)
  if not computerPos then return false end

  local distBetweenVehicleAndComputer = (computerPos-vehCenter):length()
  -- this smoothly scales the radius from 100% for 4m or less distance to 150% for 12m or more radius
  local radiusMultipler = ((clamp(distBetweenVehicleAndComputer,4,12)-4)/16 + 1)
  -- these radii are tuned for the wcusa garage!
  tether = career_modules_tether.startCapsuleTetherBetweenStatics(computerPos, 10*radiusMultipler, vehCenter, vehRadius + (9*radiusMultipler), M.cancelShopping)
  return tether ~= nil
end

local closeMenuAfterSaving
local function applyShopping()
  if switchingVehicle then return {success = false, reason = "vehicle_switch_in_progress"} end

  career_modules_vehiclePerformance.invalidateCertification(inventoryId)
  career_modules_inventory.setVehicleDirty(inventoryId)
  career_modules_playerAttributes.addAttributes({money=-shoppingCart.total}, {tags={"tuning", "buying"}, label = "ui.career.tuning.tunedVehicle"})

  gameplay_achievement.unlockAchievement("VEHICLE_TUNED")

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent({inventoryId}, {force = true})
  end
  M.close()
end

-- Close after the full save chain finishes (repair autosave may still be in
-- flight when confirm queues). onVehicleSaveFinished can fire mid-chain.
local function onSaveFinished()
  if closeMenuAfterSaving then
    M.close()
    closeMenuAfterSaving = nil
  end
end

local function getRawTuningData()
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then return end
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  if not vehData then return end
  return deepcopy(vehData.vdata.variables)
end

-- Fuel/battery fill level is not a paid tune — hide all $fuel* vars from the career tuning menu.
local function stripFuelTuningVars(variables)
  if not variables then return variables end
  for varName in pairs(variables) do
    if type(varName) == "string" and varName:sub(1, 5) == "$fuel" then
      variables[varName] = nil
    end
  end
  return variables
end

local function getTuningData()
  local variables = getRawTuningData()
  if not variables then return end
  stripFuelTuningVars(variables)
  return core_vehicle_partmgmt.translateTuningData(variables)
end

local function getOriginComputer()
  if not originComputerId then return nil end
  return freeroam_facilities.getFacility("computer", originComputerId)
end

local function isTuningTentSession()
  local computer = getOriginComputer()
  return computer ~= nil and computer.openTuningDirectly == true
end

local function getTuneableVehicleIds()
  local result = {}
  local spawnedVehicles = career_modules_inventory.getMapInventoryIdToVehId()
  local vehicles = career_modules_inventory.getVehicles()

  for _, candidateId in ipairs(career_modules_inventory.getInventoryIdsInClosestGarage() or {}) do
    local permission = career_modules_permissions and
      career_modules_permissions.getStatusForTag({"tuning", "vehicleModification"}, {inventoryId = candidateId}) or nil
    local needsRepair = career_modules_insurance_insurance and
      career_modules_insurance_insurance.inventoryVehNeedsRepair and
      career_modules_insurance_insurance.inventoryVehNeedsRepair(candidateId)

    if vehicles[candidateId] and spawnedVehicles[candidateId] and not needsRepair and
        (not permission or permission.allow) then
      table.insert(result, candidateId)
    end
  end

  return result
end

local function getTuningSessionData()
  local data = {
    activeInventoryId = inventoryId and tostring(inventoryId) or nil,
    isTuningTent = isTuningTentSession(),
    switchingVehicle = switchingVehicle,
    vehicles = {}
  }

  if not data.isTuningTent then return data end

  for _, candidateId in ipairs(getTuneableVehicleIds()) do
    local vehicleInfo = career_modules_inventory.getVehicles()[candidateId]
    if vehicleInfo then
      local niceName = vehicleInfo.niceName
      if core_locales and core_locales.translateWithOrWithoutContext then
        niceName = core_locales.translateWithOrWithoutContext(niceName)
      end
      table.insert(data.vehicles, {
        inventoryId = tostring(candidateId),
        niceName = niceName or tostring(candidateId)
      })
    end
  end

  return data
end

local function prepareVehicleSession(targetInventoryId)
  local previousInventoryId = inventoryId
  inventoryId = targetInventoryId
  local tuningData = getTuningData()
  local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
  if not tuningData or not vehicleInfo then
    inventoryId = previousInventoryId
    return false
  end

  vehicleVarsBefore = deepcopy(vehicleInfo.config.vars or {})

  -- Fill the baseline with variables whose current value only exists in JBeam.
  for varName, varTuningData in pairs(tuningData) do
    if vehicleVarsBefore[varName] == nil then
      vehicleVarsBefore[varName] = varTuningData.val
    end
  end

  shoppingCart = {}
  changedVars = {}
  return true
end

local function sendShoppingCartToUI(shoppingCartUI)
  local shoppingData = {shoppingCart = shoppingCartUI}
  shoppingData.playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  guihooks.trigger('sendTuningShoppingData', shoppingData)
end

local function createShoppingCart()
  local tuningData = getRawTuningData()
  shoppingCart = {items = {}}
  local total = 0
  for varName, value in pairs(changedVars) do
    local varData = tuningData[varName]

    -- Construct the shopping cart and calculate prices for each item
    local varPrice
    if isOnBlackList(varData) then
      shoppingCart.items[varName] = {name = varName, title = string.format("%s %s %s",
        core_vehicle_partmgmt.getTranslation(varData.category, "ui.vehicleconfig.variables.category."),
        core_vehicle_partmgmt.getTranslation(varData.subCategory, "ui.vehicleconfig.variables.subCategory."),
        core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title.")
      )}
      varPrice = 0
    elseif varData.category then
      -- Add the category to the shopping cart if it's not there yet
      if not shoppingCart.items[varData.category] then
        local price = getPriceCategory(varData.category)
        total = total + price
        shoppingCart.items[varData.category] = { type = "category", items = {}, price = price, title = core_vehicle_partmgmt.getTranslation(varData.category, "ui.vehicleconfig.variables.category.")}
      end

      -- Add the subCategory to the shopping cart if it's not there yet
      if varData.subCategory and not shoppingCart.items[varData.category].items[varData.subCategory] then
        local price = getPriceSubCategory(varData.category, varData.subCategory)
        total = total + price
        shoppingCart.items[varData.category].items[varData.subCategory] = { type = "subCategory", items = {}, price = price, title = core_vehicle_partmgmt.getTranslation(varData.subCategory, "ui.vehicleconfig.variables.subCategory.")}
      end

      if varData.subCategory then
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varData.subCategory].items[varName] = {name = varName, title = core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title."), price = varPrice}
      else
        varPrice = getPrice(varData.category, varData.subCategory, varName)
        shoppingCart.items[varData.category].items[varName] = {name = varName, title = core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title."), price = varPrice}
      end

    else
      varPrice = getPrice(varData.category, varData.subCategory, varName)
      shoppingCart.items[varName] = {name = varName, title = core_vehicle_partmgmt.getTranslation(varData.title, "ui.vehicleconfig.variables.title."), price = varPrice}
    end

    total = total + varPrice
  end

  -- Scale all prices by vehicle market index before building UI
  local vehicleMarketIndex = career_modules_globalEconomy and career_modules_globalEconomy.getVehicleMarketIndex() or 1.0
  if vehicleMarketIndex ~= 1.0 then
    total = 0
    for name, info in pairs(shoppingCart.items) do
      if info.price then
        info.price = math.floor(info.price * vehicleMarketIndex + 0.5)
      end
      for subName, subInfo in pairs(info.items or {}) do
        if subInfo.price then
          subInfo.price = math.floor(subInfo.price * vehicleMarketIndex + 0.5)
        end
        for itemName, itemInfo in pairs(subInfo.items or {}) do
          if itemInfo.price then
            itemInfo.price = math.floor(itemInfo.price * vehicleMarketIndex + 0.5)
          end
        end
      end
    end
    -- Recalculate total from scaled items
    for name, info in pairs(shoppingCart.items) do
      total = total + (info.price or 0)
      for subName, subInfo in pairs(info.items or {}) do
        total = total + (subInfo.price or 0)
        for itemName, itemInfo in pairs(subInfo.items or {}) do
          total = total + (itemInfo.price or 0)
        end
      end
    end
  end

  local shoppingCartUI = {items = {}}
  for name, info in pairs(shoppingCart.items) do
    table.insert(shoppingCartUI.items, {varName = info.name, level = 1, title = info.title, price = info.price, type = info.type})
    for name, info in pairs(info.items or {}) do
      table.insert(shoppingCartUI.items, {varName = info.name, level = 2, title = info.title, price = info.price, type = info.type})
      for name, info in pairs(info.items or {}) do
        table.insert(shoppingCartUI.items, {varName = info.name, level = 3, title = info.title, price = info.price, type = info.type})
      end
    end
  end

  shoppingCart.taxes = math.floor(total * 0.07 + 0.5)
  shoppingCart.total = total + shoppingCart.taxes
  shoppingCartUI.taxes = shoppingCart.taxes
  shoppingCartUI.total = shoppingCart.total
  sendShoppingCartToUI(shoppingCartUI)
end

local function getChangedVars(vars1, vars2)
  local res = {}
  for varName1, value1 in pairs(vars1) do
    if vars2[varName1] ~= value1 then
      res[varName1] = value1
    end
  end
  return res
end

local function startActual(_originComputerId, _returnRoute)
  originComputerId = _originComputerId
  returnRoute = _returnRoute
  -- Garage computers need an origin id. Roadside / return-route sessions open
  -- without a facility and navigate directly.
  if not originComputerId and not returnRoute then
    return
  end

  extensions.ui_router.navigate("career.computer.tuning")
  extensions.hook("onCareerTuningStarted")
  createShoppingCart()
  local veh = getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(inventoryId))
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)
  end
  if originComputerId then
    setupTether()
  end
end

local function start(_inventoryId, _originComputerId, _returnRoute)
  local targetInventoryId = _inventoryId or career_modules_inventory.getInventoryIdsInClosestGarage(true)
  if not targetInventoryId or not career_modules_inventory.getMapInventoryIdToVehId()[targetInventoryId] then return end
  if not prepareVehicleSession(targetInventoryId) then return end
  switchingVehicle = false

  local numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[inventoryId].partConditions)
  -- Roadside repair spots charge for damage; never free-fix via opening tuning there.
  if _returnRoute == "roadside-service" and numberOfBrokenParts > 0 then
    return
  end
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_valueCalculator.getBrokenPartsThreshold() then
    career_modules_insurance_insurance.startRepair(inventoryId, nil, function() startActual(_originComputerId, _returnRoute) end)
  else
    core_jobsystem.create(function(job)
      career_modules_damageManager.saveDamageState(inventoryId)
      job.sleep(0.1)
      startActual(_originComputerId, _returnRoute)
    end, 2)
  end
end

local function apply(tuningValues, callback, allowDuringVehicleSwitch)
  if switchingVehicle and not allowDuringVehicleSwitch then
    return {success = false, reason = "vehicle_switch_in_progress"}
  end

  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local oldVeh = getObjectByID(vehId)
  local vehicleTransform = {pos = oldVeh:getPosition(), rot = quat(0,0,1,0) * quat(oldVeh:getRefNodeRotation())}

  -- add the new tuning values to the existing vars and then reload the vehicle by entering again
  local vehicleVarsCurrent = career_modules_inventory.getVehicles()[inventoryId].config.vars or {}
  career_modules_inventory.getVehicles()[inventoryId].config.vars = tableMerge(vehicleVarsCurrent, tuningValues)

  career_modules_inventory.spawnVehicle(inventoryId, 2, callback)

  local veh = getObjectByID(vehId)
  spawn.safeTeleport(veh, vehicleTransform.pos, vehicleTransform.rot, nil, nil, nil, nil, false)
  core_vehicleBridge.executeAction(veh, 'setFreeze', true)

  extensions.hook("onCareerTuningApplied")

  tableMerge(changedVars, tuningValues)
  changedVars = getChangedVars(changedVars, vehicleVarsBefore)

  createShoppingCart()
  return {success = true}
end

local function removeVarFromShoppingCart(varName)
  if switchingVehicle then return {success = false, reason = "vehicle_switch_in_progress"} end

  local tuningData = getTuningData()
  local varTuningData = deepcopy(tuningData[varName])

  local vars = {}
  vars[varName] = vehicleVarsBefore[varName]
  apply(vars)

  -- send the updated tuning var to UI
  varTuningData.val = vars[varName]
  guihooks.trigger('updateTuningVariable', varTuningData)
end

local function cancelShopping()
  if changedVars and next(changedVars) then
    apply(vehicleVarsBefore, M.close)
  else
    M.close()
  end
end

-- Route-level BACK must be owned by the tuning UI so it can confirm/discard
-- changes before this module chooses the correct destination for the facility.
local function requestExit()
  guihooks.trigger("tuningRequestExit")
end

local function switchVehicle(targetInventoryId)
  targetInventoryId = tonumber(targetInventoryId)
  if switchingVehicle then
    return {success = false, reason = "vehicle_switch_in_progress"}
  end
  if not isTuningTentSession() then
    return {success = false, reason = "not_tuning_tent"}
  end
  if targetInventoryId == inventoryId then
    return {success = true, unchanged = true, data = getTuningSessionData()}
  end

  local validTarget = false
  for _, candidateId in ipairs(getTuneableVehicleIds()) do
    if candidateId == targetInventoryId then
      validTarget = true
      break
    end
  end
  if not validTarget then
    return {success = false, reason = "vehicle_unavailable"}
  end

  switchingVehicle = true
  local previousInventoryId = inventoryId

  local function finishSwitch()
    local previousVehicleId = career_modules_inventory.getVehicleIdFromInventoryId(previousInventoryId)
    local previousVehicle = previousVehicleId and getObjectByID(previousVehicleId) or nil
    if previousVehicle then
      core_vehicleBridge.executeAction(previousVehicle, 'setFreeze', false)
    end
    if tether then
      tether.remove = true
      tether = nil
    end

    career_modules_damageManager.saveDamageState(targetInventoryId)
    core_jobsystem.create(function(job)
      job.sleep(0.1)
      if not prepareVehicleSession(targetInventoryId) then
        prepareVehicleSession(previousInventoryId)
        local previousVehicleId = career_modules_inventory.getVehicleIdFromInventoryId(previousInventoryId)
        local previousVehicle = previousVehicleId and getObjectByID(previousVehicleId) or nil
        if previousVehicle then
          core_vehicleBridge.executeAction(previousVehicle, 'setFreeze', true)
          setupTether()
        end
        switchingVehicle = false
        guihooks.trigger('careerTuningVehicleChanged', {
          success = false,
          reason = "vehicle_tuning_data_unavailable"
        })
        return
      end

      createShoppingCart()
      local targetVehicleId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
      local targetVehicle = targetVehicleId and getObjectByID(targetVehicleId) or nil
      if targetVehicle then
        core_vehicleBridge.executeAction(targetVehicle, 'setFreeze', true)
      end
      setupTether()
      switchingVehicle = false

      local sessionData = getTuningSessionData()
      sessionData.success = true
      guihooks.trigger('careerTuningVehicleChanged', sessionData)
    end, 2)
  end

  -- Applied previews live on the spawned vehicle. Restore that vehicle before
  -- moving the session/tether to another one. Pure UI edits need no respawn.
  if changedVars and next(changedVars) then
    apply(vehicleVarsBefore, finishSwitch, true)
  else
    finishSwitch()
  end

  return {success = true, pending = true}
end

local function close()
  if switchingVehicle then return end

  local computer = getOriginComputer()
  local vehicleId = inventoryId and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
  local vehicle = vehicleId and getObjectByID(vehicleId) or nil
  if vehicle then
    core_vehicleBridge.executeAction(vehicle, 'setFreeze', false)
  end
  if tether then
    tether.remove = true
    tether = nil
  end

  local route = returnRoute
  returnRoute = nil
  originComputerId = nil

  -- Roadside Service (and similar) ask to return to a specific route.
  if route and extensions.ui_router and extensions.ui_router.navigate then
    extensions.ui_router.navigate(route)
    return
  end

  -- Tuning tents are tuning-only spots; there is no computer menu to return to.
  if computer and not computer.openTuningDirectly then
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["tuning"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local computerFunctionData = {
      id = "tuning",
      routeTarget = "career.computer.tuning",
      label = _tr("ui.career.shared.pathTuning"),
      callback = function() start(vehicleData.inventoryId, menuData.computerFacility.id) end,
      disabled = buttonDisabled,
      order = 10
    }
    -- vehicle broken
    if vehicleData.needsRepair then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.needsRepair
    end
    -- tutorial active
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
    end

    -- generic gameplay reason
    local inventoryId = vehicleData.inventoryId
    local reason = career_modules_permissions.getStatusForTag({"tuning", "vehicleModification"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

M.start = start
M.apply = apply
M.getTuningData = getTuningData
M.close = close
M.applyShopping = applyShopping
M.cancelShopping = cancelShopping
M.requestExit = requestExit
M.removeVarFromShoppingCart = removeVarFromShoppingCart
M.getTuningSessionData = getTuningSessionData
M.switchVehicle = switchVehicle

M.onComputerAddFunctions = onComputerAddFunctions
M.onSaveFinished = onSaveFinished

return M
