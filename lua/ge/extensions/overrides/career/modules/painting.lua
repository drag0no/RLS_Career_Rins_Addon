-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career", "gameplay_achievement"}

local blockedInputActions = core_input_actionFilter.createActionTemplate({"walkingMode", "bigMap"})

local paintingActive

local inventoryId

-- When set, painting operates on a business fleet vehicle instead of the
-- player's career inventory. The paint UI is identical; only the data source,
-- payment method and save target differ.
-- Shape: { businessId=string|number, vehicleId=string|number, vehObjId=number }
local businessCtx

local originComputerId
local chosenPaints
local chosenPackage
local walkingPositionBefore
local previousDefaultRotation

local prices = {
  basePrices = {
    factory = {money = {amount = 600, canBeNegative = false}},
    semiGloss = {money = {amount = 1000, canBeNegative = false}},
    gloss = {money = {amount = 1500, canBeNegative = false}},
    semiMetallic = {money = {amount = 1500, canBeNegative = false}},
    metallic = {money = {amount = 2500, canBeNegative = false}},
    matte = {money = {amount = 1800, canBeNegative = false}},
    chrome = {money = {amount = 3400, canBeNegative = false}},
    custom = {money = {amount = 4000, canBeNegative = false}},
  },
  clearcoatBase = {money = {amount = 500, canBeNegative = false}},
  clearcoatPolishFactor = {money = {amount = 1000, canBeNegative = false}},
}

local colorClassData = {
  semiGloss = {metallic = 0, roughness = 0.13},
  gloss = {metallic = 0, roughness = 0},
  semiMetallic = {metallic = 0.5, roughness = 0.5},
  metallic = {metallic = 1, roughness = 0.5},
  matte = {metallic = 0, roughness = 0.7},
  chrome = {metallic = 1, roughness = 0}
}

local function getPrimerColor()
  local brightnessOffset = (math.random() * 2 - 1) * 0 -- no randomness for now
  local paint = {
    baseColor = {0.58 + brightnessOffset, 0.58 + brightnessOffset, 0.585 + brightnessOffset},
    clearcoat = 0,
    clearcoatRoughness = 1,
    metallic = 0,
    roughness = 0.475,
  }

  return paint
end

local function findBaseColors(partConditions)
  local colors
  for partPath, partCondition in pairs(partConditions) do
    if not colors then
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        colors = partCondition.visualState.paint.originalPaints
      end
    end
    if string.find(partPath, "body") then
      if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
        return partCondition.visualState.paint.originalPaints
      end
    end
  end
  return colors
end

-- Business-context helpers ----------------------------------------------------

local function getBusinessVehicleRecord()
  if not businessCtx then return nil end
  if not career_modules_business_businessInventory then return nil end
  return career_modules_business_businessInventory.getVehicleById(businessCtx.businessId, businessCtx.vehicleId)
end

local function getBusinessVehObj()
  if not businessCtx then return nil end
  return businessCtx.vehObjId and getObjectByID(businessCtx.vehObjId) or nil
end

local function getPaintData()
  local data = {}
  local partConditions
  if businessCtx then
    local record = getBusinessVehicleRecord()
    partConditions = record and record.partConditions or {}
  else
    local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
    partConditions = vehicleInfo.partConditions
  end
  local colors = findBaseColors(partConditions)
  data.colors = colors
  data.prices = prices
  data.colorClassData = colorClassData
  return data
end

local function startActual(_originComputerId)
  paintingActive = true
  chosenPaints = nil
  chosenPackage = nil
  originComputerId = _originComputerId
  -- Biz-mode sessions have no originComputerId but still need the painting UI to open.
  if originComputerId or businessCtx then
    extensions.ui_router.navigate('career.computer.painting')
  end

  if gameplay_walk.isWalking() then
    walkingPositionBefore = getPlayerVehicle(0):getPosition()
  end

  core_input_actionFilter.setGroup('paintingBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'paintingBlockedActions', true)

  guihooks.trigger("onCareerPaintingStarted")
end

local function start(_inventoryId, _originComputerId)
  -- Ensure we're starting clean; a biz session must not leak into a player session.
  businessCtx = nil
  inventoryId = _inventoryId or career_modules_inventory.getInventoryIdsInClosestGarage(true)
  if not inventoryId or not career_modules_inventory.getMapInventoryIdToVehId()[inventoryId] then return end

  local numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[inventoryId].partConditions)
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_valueCalculator.getBrokenPartsThreshold() then
    career_modules_insurance_insurance.startRepair(inventoryId, nil, function() startActual(_originComputerId) end)
  else
    core_jobsystem.create(function(job)
      career_modules_damageManager.saveDamageState(inventoryId)
      job.sleep(0.1)
      startActual(_originComputerId)
    end, 2)
  end
end

-- Paint a business fleet vehicle. The vehicle must already be spawned (pulled out)
-- via career_modules_business_businessInventory so that setPaints/onUIOpened can
-- operate on the live vehicle object. Payment is deducted from the business account.
local function startForBusinessVehicle(businessId, vehicleId, _originComputerId)
  if not businessId or not vehicleId then return false, "badArgs" end
  if not career_modules_business_businessInventory then return false, "noBusinessInventory" end

  local record = career_modules_business_businessInventory.getVehicleById(businessId, vehicleId)
  if not record then return false, "noVehicle" end

  local spawnedId = career_modules_business_businessInventory.getSpawnedVehicleId and
    career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
  if not spawnedId or not getObjectByID(spawnedId) then
    return false, "notPulledOut"
  end

  -- Block painting a severely broken vehicle (mirrors the player flow threshold).
  if career_modules_valueCalculator and career_modules_valueCalculator.getNumberOfBrokenParts and record.partConditions then
    local brokenCount = career_modules_valueCalculator.getNumberOfBrokenParts(record.partConditions)
    local threshold = career_modules_valueCalculator.getBrokenPartsThreshold and career_modules_valueCalculator.getBrokenPartsThreshold() or 0
    if brokenCount >= threshold and threshold > 0 then
      return false, "needsRepair"
    end
  end

  inventoryId = nil
  businessCtx = {
    businessId = businessId,
    vehicleId = vehicleId,
    vehObjId = spawnedId,
  }
  startActual(_originComputerId)
  return true
end

-- Populated by close() for biz-mode sessions so closeMenu() can route back to
-- the business computer UI after businessCtx has been cleared.
local pendingBizReturn

local function closeMenu()
  if pendingBizReturn then
    local info = pendingBizReturn
    pendingBizReturn = nil
    extensions.ui_router.navigate('business-computer', {
      businessType = info.businessType,
      businessId = info.businessId,
    })
  elseif originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

-- Restores vehicle/camera/input state. Does NOT navigate; the router owns the
-- transition back to career.computer. Safe to call from the UI on unmount.
local function cleanup()
  if not paintingActive then return end

  local bizMode = businessCtx ~= nil

  closeMenuAfterSaving = (not bizMode) and career_career.isAutosaveEnabled() and _closeMenuAfterSaving

  if bizMode then
    -- Biz vehicle is already spawned; unfreeze it rather than respawning the player vehicle.
    local vehObj = getBusinessVehObj()
    if vehObj and core_vehicleBridge and core_vehicleBridge.executeAction then
      core_vehicleBridge.executeAction(vehObj, 'setFreeze', false)
    end
  else
    career_modules_inventory.spawnVehicle(inventoryId, 2)
  end

  local camData = core_camera.getCameraDataById(be:getPlayerVehicleID(0))
  if previousDefaultRotation and camData and camData.orbit then
    camData.orbit:setDefaultRotation(previousDefaultRotation)
    camData.orbit:init()
  end

  if walkingPositionBefore then
    local vehPos = getPlayerVehicle(0):getPosition()
    core_vehicleBridge.executeAction(getPlayerVehicle(0),'setFreeze', false)
    gameplay_walk.setWalkingMode(true, walkingPositionBefore, quatFromDir(vehPos - walkingPositionBefore))
    walkingPositionBefore = nil
  end

  core_input_actionFilter.setGroup('paintingBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'paintingBlockedActions', false)
  scenetree.OnlyGui:setFrustumCameraCenterOffset(Point2F(0, 0))
  paintingActive = nil
end

local closeMenuAfterSaving
local function close(_closeMenuAfterSaving)
  if not paintingActive then return end

  closeMenuAfterSaving = career_career.isAutosaveEnabled() and _closeMenuAfterSaving

  cleanup()

  if bizMode then
    -- Stash info for closeMenu() so we can navigate back to the biz computer
    -- after businessCtx is cleared. Racing Team is the only supported type today.
    pendingBizReturn = {
      businessId = businessCtx.businessId,
      businessType = "racingTeam",
    }
    businessCtx = nil
  end

  if not closeMenuAfterSaving then
    closeMenu()
  end
end

local function onSaveFinished()
  if closeMenuAfterSaving then
    closeMenu()
    closeMenuAfterSaving = nil
  end
end

local function getTotalPrice(package)
  local total = {money = {amount = 0, canBeNegative = false}}
  for index, paintOptions in ipairs(package) do
    if not tableIsEmpty(paintOptions) then
      total.money.amount = total.money.amount + prices.basePrices[paintOptions.paintClass].money.amount
      if paintOptions.clearCoat then
        total.money.amount = total.money.amount + prices.clearcoatBase.money.amount
        total.money.amount = total.money.amount + paintOptions.clearCoatPolish * prices.clearcoatPolishFactor.money.amount
      end
    end
  end
  -- Scale paint costs by global economy index
  local globalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  total.money.amount = math.floor(total.money.amount * globalIndex)
  return total
end

local function apply()
  local price = getTotalPrice(chosenPackage)

  if businessCtx then
    -- Charge the business account directly. We use racingTeamFinances for the
    -- debit so the Paint cost shows up in the finance widget ledger.
    local amount = math.max(0, math.floor((price and price.money and price.money.amount) or 0))
    if career_modules_business_racingTeamFinances and career_modules_business_racingTeamFinances.tryDebitVehiclePaintCost then
      local ok = career_modules_business_racingTeamFinances.tryDebitVehiclePaintCost(businessCtx.businessId, amount)
      if not ok then return end
    elseif amount > 0 then
      -- Finance module missing; don't silently apply free paint.
      return
    end
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')

    if chosenPaints then
      local record = getBusinessVehicleRecord()
      if record then
        record.config = record.config or {}
        record.config.paints = deepcopy(chosenPaints)
        if record.partConditions then
          for _, partCondition in pairs(record.partConditions) do
            if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
              partCondition.visualState.paint.odometer = 0
              partCondition.visualState.paint.originalPaints = deepcopy(chosenPaints)
            end
          end
        end
        -- Persist to disk so the paint survives put-away/pull-out and reloads.
        if career_modules_business_businessInventory and career_modules_business_businessInventory.saveBusinessVehicles then
          local _, savePath = career_saveSystem.getCurrentProfile()
          if savePath then
            career_modules_business_businessInventory.saveBusinessVehicles(businessCtx.businessId, savePath)
          end
        end
      end
    end

    close()
    return
  end

  if not career_modules_payment.canPay(price) then return end
  career_modules_payment.pay(price, {label = _tr("ui.career.painting.payment.repaintedVehicle"), tags = {"vehiclePainting", "buying"}})
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')

  if chosenPaints then
    local vehicle = career_modules_inventory.getVehicles()[inventoryId]
    vehicle.config.paints = deepcopy(chosenPaints)
    for partPath, partCondition in pairs(vehicle.partConditions) do
      if partCondition.visualState and partCondition.visualState.paint.originalPaints then
        -- TODO this always sets the odometer of all 3 paints back to 0
        partCondition.visualState.paint.odometer = 0
        partCondition.visualState.paint.originalPaints = chosenPaints

        local partId = career_modules_partInventory.getPartPathToPartIdMap()[inventoryId][partPath]
        if partId then
          career_modules_partInventory.getInventory()[partId].primered = nil
        end
      end
    end
  end

  gameplay_achievement.unlockAchievement("VEHICLE_MODIFIED")
  close()
  career_modules_inventory.setVehicleDirty(inventoryId)
  career_saveSystem.saveCurrent({inventoryId}, {force = true})
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["painting"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local computerFunctionData = {
      id = "painting",
      routeTarget = "career.computer.painting",
      label = _tr("ui.career.shared.pathPainting"),
      callback = function() start(vehicleData.inventoryId, menuData.computerFacility.id) end,
      order = 15
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
    local reason =  career_modules_permissions.getStatusForTag({"painting", "vehicleModification"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function businessCanAfford(amount)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount <= 0 then return true end
  if not businessCtx then return false end
  if not career_modules_bank or not career_modules_bank.getBusinessAccount then return false end
  local account = career_modules_bank.getBusinessAccount("racingTeam", businessCtx.businessId)
  if not account then return false end
  local balance = tonumber(account.balance) or 0
  return balance >= amount
end

local function sendShoppingCartData(package)
  local data = {}
  data.totalPrice = getTotalPrice(package)
  if businessCtx then
    data.canPay = businessCanAfford(data.totalPrice and data.totalPrice.money and data.totalPrice.money.amount or 0)
  else
    data.canPay = career_modules_payment.canPay(data.totalPrice)
  end
  guihooks.trigger("sendPaintingShoppingCartData", data)
end

local function setPaints(paints, paintOptions, partName)
  chosenPaints = paints
  chosenPackage = paintOptions

  sendShoppingCartData(chosenPackage)

  if tableSize(chosenPaints) < 3 then
    for i = tableSize(chosenPaints)+1, 3 do
      chosenPaints[i] = chosenPaints[i-1]
    end
  end

  local vehObjId
  local vehicleObject
  if businessCtx then
    vehObjId = businessCtx.vehObjId
    vehicleObject = getBusinessVehObj()
  else
    vehObjId = career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
    vehicleObject = getObjectByID(vehObjId)
  end
  if not vehicleObject then return end
  extensions.core_vehicle_colors.setVehiclePaint(1, chosenPaints[1], vehObjId)
  extensions.core_vehicle_colors.setVehiclePaint(2, chosenPaints[2], vehObjId)
  extensions.core_vehicle_colors.setVehiclePaint(3, chosenPaints[3], vehObjId)
  if partName then
    vehicleObject:queueLuaCommand(string.format("partCondition.setPartPaints(%s, %s, 0)", partName, serialize(chosenPaints)))
  else
    vehicleObject:queueLuaCommand(string.format("partCondition.setAllPartPaints(%s, 0)", serialize(chosenPaints)))
  end
end

local function getFactoryPaint()
  local id
  if businessCtx then
    id = businessCtx.vehObjId
  else
    id = career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
  end
  if not id then return {} end
  local info = core_vehicles.getVehicleDetails(id)
  return info.model and info.model.paints or {}
end

local function sendPaintingDataToUI()
  if not paintingActive then return end
  local data = getPaintData()
  data.factoryPaint = getFactoryPaint()
  guihooks.trigger("paintingData", data)
end

-- Router lifecycle: re-emit the painting data once the destination view has mounted.
local function onRouteMount(context, toRoute, fromRoute, data)
  sendPaintingDataToUI()
end

local function onUIOpened()
  local vehId
  if businessCtx then
    vehId = businessCtx.vehObjId
  else
    vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  end
  if not vehId then return end
  local veh = getObjectByID(vehId)
  if not veh then return end
  core_vehicleBridge.requestValue(veh, function()
    if businessCtx then
      -- Switch camera/focus to the biz vehicle (it's already spawned/parked).
      be:enterVehicle(0, veh)
    else
      career_modules_inventory.enterVehicle(inventoryId)
    end
    core_vehicleBridge.executeAction(veh,'setFreeze', true)

    -- we use setDefaultRotation instead of setRotation, because that one doesnt work reliably
    local vehCamData = core_camera.getCameraDataById(be:getPlayerVehicleID(0)).orbit
    if vehCamData then
      previousDefaultRotation = vehCamData.defaultRotation
    end
    core_camera.setByName(0, "orbit", true)
    core_camera.setDefaultRotation(vehId, vec3(145, -15, 0))
    core_camera.resetCamera(0)
    scenetree.OnlyGui:setFrustumCameraCenterOffset(Point2F(-0.3125, 0))
    extensions.hook("onVehiclePaintingUiOpened")
  end, 'ping')
end

M.start = start
M.startForBusinessVehicle = startForBusinessVehicle
M.apply = apply
M.close = close
M.cleanup = cleanup
M.getPaintData = getPaintData
M.setPaints = setPaints
M.getFactoryPaint = getFactoryPaint
M.sendPaintingDataToUI = sendPaintingDataToUI

M.getPrimerColor = getPrimerColor

M.onComputerAddFunctions = onComputerAddFunctions
M.onUIOpened = onUIOpened
M.onRouteMount = onRouteMount
M.onSaveFinished = onSaveFinished

return M
