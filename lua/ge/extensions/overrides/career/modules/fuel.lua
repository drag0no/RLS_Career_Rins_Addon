-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}
local imgui = ui_imgui

local maxFuelFlowRate = 50000000
local fuelFlowRate = maxFuelFlowRate

local fuelData
local fuelingActive = {}
local energyTypeFuelingActive = {}
local energyTypes = {}
local defaultEnergyType
local selectedTankIndex = 1

local startingFuelData
local fuelingData = {}
local overallPrice = 0

local gasSoundId
local electricSoundId

local isSoundPlaying = {}

local showUI

local gasStation -- The gasstation where the refueling was started
local fuelDiscountData = {} -- Store discount data for the current transaction
local debugIgnoreStationFuelTypeRestriction = false

-- When refueling a business fleet vehicle this holds { businessId, vehicleId, vehObjId }
-- so pay/end logic can route the charge to the business account and skip player
-- inventory lookups.
local businessCtx

-- Populated by startForBusinessVehicle() when the refuel transaction was initiated
-- from the Business Computer UI (e.g. Racing Team "Pit Fuel" skill). Consumed by
-- endTransaction() to route the UI back to the business-computer state.
local pendingBizReturn

-- Synthetic gas-station identifier for in-shop refueling. Used to signal to the
-- pricing code that we should bill the level's average pump price rather than a
-- real station's price, and to label the UI/ledger entry.
local SHOP_STATION_ID = "shopStockpile"

-- Returns the vehicle object to pump against. In business mode we ignore
-- getPlayerVehicle(0) entirely: the player may still be in walking mode / in
-- another vehicle because the business-computer UI is driving the flow, and we
-- want every fuel read/write to hit the actual fleet vehicle we chose.
local function getFuelingVehicle()
  if businessCtx and businessCtx.vehObjId then
    local obj = getObjectByID(businessCtx.vehObjId)
    if obj then return obj end
  end
  return getPlayerVehicle(0)
end

-- Inventory "current" can be unset after realistic walk-enter; fall back to the
-- owned vehicle the player is actually seated in so refuel still works.
local function resolvePlayerInventoryId()
  local invId = career_modules_inventory.getCurrentVehicle()
  if invId then return invId end
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if playerVehId and playerVehId > 0 then
    return career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
  end
  return nil
end

local function detectBusinessCtxForPlayerVehicle()
  if not career_modules_business_businessInventory or
     not career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId then
    return nil
  end
  local objId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if not objId or objId < 0 then return nil end
  local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(objId)
  if not businessId or not vehicleId then return nil end
  return { businessId = businessId, vehicleId = vehicleId, vehObjId = objId }
end

local factorMJToReadable = {
  gasoline = 31.125,
  diesel = 36.112,
  kerosine = 34.4,
  n2o = 8.3,
  electricEnergy = 3.6
}

local readableUnit = {
  gasoline = "L",
  diesel = "L",
  kerosine = "L",
  n2o = "kg",
  electricEnergy = "kWh"
}

local isCurrentlyFueling

local function setDefaultEnergyType(energyType)
  defaultEnergyType = energyType
end

local function jouleToReadableUnit(value, fuelType)
  return value / 1000000 / factorMJToReadable[fuelType]
end

local function initializeDefaultEnergyType()
  local defaultTypeCandidate

  -- if the vehicle has one of these types, use this as default
  for i, energyType in ipairs(energyTypes) do
    if energyType == "gasoline" or energyType == "diesel" or energyType == "kerosine" then
      defaultTypeCandidate = energyType
      break
    end
  end

  if not defaultTypeCandidate then
    for i, energyType in ipairs(energyTypes) do
      if energyType == "electricEnergy" then
        defaultTypeCandidate = energyType
        break
      end
    end
  end

  setDefaultEnergyType(defaultTypeCandidate)
end

-- For the shop-stockpile refueling flow we don't have a real gas station, so
-- compute the current average price across every station on the level that
-- sells this fuel type. Falls back to a real station's price if only one is
-- cached, and finally to 1.0 if nothing is available yet (e.g. signs haven't
-- refreshed since mission start).
local function getShopAveragePrice(energyType)
  if not freeroam_facilities or not freeroam_facilities_fuelPrice then return nil end
  local facilities
  if freeroam_facilities.getCurrentLevelFacilities then
    facilities = freeroam_facilities.getCurrentLevelFacilities()
  end
  if not facilities or not facilities.gasStations then return nil end
  local sum, count = 0, 0
  for _, st in ipairs(facilities.gasStations) do
    if st and st.id then
      local p = freeroam_facilities_fuelPrice.getFuelPrice(st.id, energyType)
      if p and p > 0 then
        sum = sum + p
        count = count + 1
      end
    end
  end
  if count == 0 then return nil end
  return sum / count
end

local function getPricePerUnit(energyType)
  local basePrice
  if gasStation and gasStation.facility and gasStation.facility.id == SHOP_STATION_ID then
    basePrice = getShopAveragePrice(energyType) or 1
    -- Shop refueling never gets the insurance discount (per design).
    return basePrice
  end
  basePrice = freeroam_facilities_fuelPrice.getFuelPrice(gasStation.facility.id, energyType) or 1
  if fuelDiscountData.hasFuelDiscount then
    return basePrice * (1 - fuelDiscountData.fuelDiscount) -- apply insurance discount
  end
  return basePrice
end

local function gasStationOffersFuelType(energyType)
  if debugIgnoreStationFuelTypeRestriction then return true end
  if not (gasStation and gasStation.facility and gasStation.facility.id) then return true end
  -- Shop refueling runs against a synthetic station that fuelPrice has no entry for,
  -- and getShopAveragePrice can legitimately be nil before the pump signs refresh.
  -- The stockpile dispenses any type (getPricePerUnit falls back to 1), so never filter here.
  if gasStation.facility.id == SHOP_STATION_ID then return true end
  return freeroam_facilities_fuelPrice.getFuelPrice(gasStation.facility.id, energyType) ~= nil
end

local function getCurrentVehicleData()
  local currentVehicleId = resolvePlayerInventoryId()
  return currentVehicleId and career_modules_inventory.getVehicles()[currentVehicleId]
end

local function canPayPrice()
  if overallPrice <= 0 then return false end
  -- Business fleet refuels are billed to the team account (with a personal-money
  -- fallback inside payPrice), so the player's balance must not gate the pump.
  if businessCtx then return true end
  local currentVehicle = getCurrentVehicleData()
  if currentVehicle and currentVehicle.loanType == "work" then return true end
  return overallPrice <= career_modules_playerAttributes.getAttributeValue("money")
end

local function sendInitialDataToUI()
  local levelInfoData = core_levels.getLevelByName(getCurrentLevelIdentifier())
  local localUnits = {}
  if levelInfoData then
    localUnits = levelInfoData.localUnits or {}
  end

  -- check for fuel discount via the current insurance
  fuelDiscountData = {}
  if career_career.isActive() then
    local currentVehicleId = resolvePlayerInventoryId()
    if currentVehicleId then
      fuelDiscountData = career_modules_insurance_insurance.getInvVehFuelDiscountData(currentVehicleId)
    end
  end

  local uiUpdateData = {}
  uiUpdateData.energyTypesToLocalUnits = localUnits
  uiUpdateData.energyTypes = energyTypes
  uiUpdateData.selectedTankIndex = selectedTankIndex
  uiUpdateData.gasStationName = gasStation.facility.name
  uiUpdateData.fuelData = {}
  for i, tank in ipairs(fuelData) do
    local tankData = {}
    tankData.energyType = tank.energyType
    tankData.tankIndex = i
    tankData.tankName = tank.name
    tankData.currentEnergy = jouleToReadableUnit(tank.currentEnergy, tank.energyType)
    tankData.maxEnergy = jouleToReadableUnit(tank.maxEnergy, tank.energyType)
    tankData.pricePerUnit = getPricePerUnit(tank.energyType)
    uiUpdateData.fuelData[i] = tankData
  end

  if fuelDiscountData.hasFuelDiscount then
    uiUpdateData.fuelDiscountData = fuelDiscountData
  end

  guihooks.trigger('initialFuelingData', uiUpdateData)
end

local function sendUpdateDataToUI()
  local uiUpdateData = {}
  uiUpdateData.fuelData = {}
  uiUpdateData.overallPrice = overallPrice
  uiUpdateData.canPay = canPayPrice()
  for i, tank in ipairs(fuelData) do
    local tankData = {}
    tankData.energyType = tank.energyType
    tankData.tankIndex = i
    tankData.tankName = tank.name
    tankData.currentEnergy = jouleToReadableUnit(tank.currentEnergy, tank.energyType)
    tankData.fueledEnergy = jouleToReadableUnit(fuelingData[i].fueledEnergy, tank.energyType)
    tankData.price = fuelingData[i].price
    tankData.fuelingActive = fuelingActive[i]
    uiUpdateData.fuelData[i] = tankData
  end
  uiUpdateData.flowRate = fuelFlowRate / maxFuelFlowRate

  guihooks.trigger('updateFuelData', uiUpdateData)
end

local function saveEnergyStorageData(data)
  fuelData = {}
  for _, tank in ipairs(data[1]) do
    -- only add tanks that this station can actually fill
    if factorMJToReadable[tank.energyType] and gasStationOffersFuelType(tank.energyType) then
      table.insert(fuelData, tank)
    end
  end
  showUI = true
  selectedTankIndex = 1
  defaultEnergyType = fuelData[selectedTankIndex] and fuelData[selectedTankIndex].energyType or nil
  for i, data in ipairs(fuelData) do
    table.insert(fuelingData, {price = 0, fueledEnergy = 0})
  end

  table.clear(energyTypes)
  for index, tankData in ipairs(fuelData) do
    if not tableContains(energyTypes, tankData.energyType) then
      table.insert(energyTypes, tankData.energyType)
    end
  end
  sendInitialDataToUI()
end

local function requestEnergyStorageData()
  local veh = getFuelingVehicle()
  core_vehicleBridge.requestValue(veh, saveEnergyStorageData, 'energyStorage')
end

local function startAngularUI()
  extensions.ui_router.navigate("career.refueling")
end

local function requestRefuelingTransactionData()
  requestEnergyStorageData()
end

local function startTransaction(_gasStation)
  -- startForBusinessVehicle() may have already populated businessCtx before
  -- calling us; only auto-detect if no context has been supplied.
  if not businessCtx then
    businessCtx = detectBusinessCtxForPlayerVehicle()
  end
  if not businessCtx and not resolvePlayerInventoryId() then return end
  gasStation = _gasStation
  if freeroam_facilities_fuelPrice and freeroam_facilities_fuelPrice.setDisplayPrices then
    freeroam_facilities_fuelPrice.setDisplayPrices()
  end
  pushActionMap("Refueling")
  local txVeh = getFuelingVehicle()
  if txVeh then
    core_vehicleBridge.executeAction(txVeh, 'setIgnitionLevel', 0)
  end
  startAngularUI()
  extensions.hook("onRefuelingStartTransaction")
end

local function getFuelData()
  return fuelData
end

local function applyFuelData(data, veh)
  if showUI then
    sendUpdateDataToUI()
  end
  veh = veh or getFuelingVehicle()
  for index, tankData in ipairs(data or fuelData) do
    core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tankData.name, tankData.currentEnergy)
  end
end

local function restoreFuelData(data, veh)
  veh = veh or getFuelingVehicle()
  for index, tankData in ipairs(data or {}) do
    fuelData[index].currentEnergy = tankData.currentEnergy
    core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tankData.name, tankData.currentEnergy)
  end
end

local function activateSound(soundId, active)
  local sound = scenetree.findObjectById(soundId)
  if sound then
    if active then
      sound:play(-1)
    else
      sound:stop(-1)
    end
    sound:setTransform(getCameraTransform())
    isSoundPlaying[soundId] = active
  end
end

local function getGasFuelLevelInfo()
  local maxVolume = 0
  local currentVolume = 0
  for index, data in ipairs(fuelData) do
    if data.energyType == "gasoline" or data.energyType == "diesel" or data.energyType == "kerosine" then
      currentVolume = currentVolume + data.currentEnergy
      maxVolume = maxVolume + data.maxEnergy
    end
  end
  return currentVolume, maxVolume, maxVolume > 0 and currentVolume / maxVolume or nil
end

local function getRelativeFuelLevel()
  local _, _, relativeFuelLevel = getGasFuelLevelInfo()
  return relativeFuelLevel or 0
end

local function updateFuelSoundParameters()
  local relativeFuelLevel = getRelativeFuelLevel()
  local sound = scenetree.findObjectById(gasSoundId)
  if sound then
    sound:setParameter("volume", relativeFuelLevel)
    sound:setParameter("pitch", fuelFlowRate / maxFuelFlowRate)
    sound:setTransform(getCameraTransform())
  end
end

local function updateFuelingFlags()
  table.clear(energyTypeFuelingActive)
  for i, data in ipairs(fuelingActive) do
    if fuelingActive[i] then
      energyTypeFuelingActive[fuelData[i].energyType] = true
    end
  end

  if energyTypeFuelingActive["gasoline"] or energyTypeFuelingActive["diesel"] or energyTypeFuelingActive["kerosine"] then
    if not isSoundPlaying[gasSoundId] then
      activateSound(gasSoundId, true)
    end
  else
    if isSoundPlaying[gasSoundId] then
      updateFuelSoundParameters()
      activateSound(gasSoundId, false)
    end
  end

  if energyTypeFuelingActive["electricEnergy"] then
    if not isSoundPlaying[electricSoundId] then
      activateSound(electricSoundId, true)
    end
  else
    if isSoundPlaying[electricSoundId] then
      updateFuelSoundParameters()
      activateSound(electricSoundId, false)
    end
  end
end

local function stopFuelingTank(index, applyData)
  fuelingActive[index] = false
  if applyData == nil then applyData = true end
  if applyData then
    updateFuelingFlags()
    applyFuelData()
  end
  extensions.hook("onRefuelingStopFueling", fuelData[index])
end

local function startFuelingTank(index)
  if businessCtx or resolvePlayerInventoryId() then
    local veh = getFuelingVehicle()
    if not veh then return end
    if veh:getVelocity():length() < 1 then
      fuelingActive[index] = true
      startingFuelData = startingFuelData or deepcopy(fuelData)
    end
  end
end

local function startFuelingType(energyType)
  for index, data in ipairs(fuelData) do
    if data.energyType == energyType then
      startFuelingTank(index)
    end
  end
  updateFuelingFlags()
end

local function stopFuelingType(energyType)
  for index, data in ipairs(fuelData) do
    if not energyType or (data.energyType == energyType) then
      stopFuelingTank(index, false)
    end
  end
  updateFuelingFlags()
  applyFuelData()
end

local function getValidTankIndex(index)
  if not fuelData or not next(fuelData) then return nil end
  index = clamp(tonumber(index) or selectedTankIndex or 1, 1, #fuelData)
  return fuelData[index] and index or nil
end

local function onChangeFlowRate(factor, tankIndex)
  if not gasStation then return end
  local validIndex = getValidTankIndex(tankIndex or selectedTankIndex)
  if not validIndex then
    return
  end
  selectedTankIndex = validIndex
  defaultEnergyType = fuelData[selectedTankIndex].energyType

  factor = clamp(factor, 0, 1)
  if factor <= 0 then
    stopFuelingTank(selectedTankIndex)
    fuelFlowRate = maxFuelFlowRate
    return
  end
  fuelFlowRate = maxFuelFlowRate * factor
  if not fuelingActive[selectedTankIndex] and fuelData[selectedTankIndex].currentEnergy < fuelData[selectedTankIndex].maxEnergy then
    startFuelingTank(selectedTankIndex)
    updateFuelingFlags()
    sendUpdateDataToUI()
  end
end

local function getFuelingData()
  return fuelingData
end

local function endTransaction()
  popActionMap("Refueling")
  table.clear(fuelingData)
  table.clear(fuelingActive)
  table.clear(energyTypeFuelingActive)
  table.clear(energyTypes)
  showUI = false
  overallPrice = 0
  startingFuelData = nil
  fuelData = nil
  defaultEnergyType = nil
  selectedTankIndex = 1
  fuelFlowRate = maxFuelFlowRate
  fuelDiscountData = {}
  activateSound(gasSoundId, false)
  activateSound(electricSoundId, false)
  local bizMode = businessCtx ~= nil
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  elseif not bizMode then
    career_modules_inventory.updatePartConditions(nil, resolvePlayerInventoryId())
  end
  businessCtx = nil

  -- Route back to the Business Computer UI when this transaction was started
  -- from the shop-stockpile flow, otherwise fall through to gameplay.
  if pendingBizReturn then
    local info = pendingBizReturn
    pendingBizReturn = nil
    extensions.ui_router.navigate('business-computer', {
      businessType = info.businessType,
      businessId = info.businessId,
    })
  else
    extensions.ui_router.navigate('play')
  end
  extensions.hook("onRefuelingEndTransaction")
end

local function payPrice()
  if not canPayPrice() then return end
  if overallPrice > 0 then
    Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  end
  stopFuelingType()

  local stationName = (gasStation and gasStation.facility and gasStation.facility.name) or "fuel station"
  local stationLabel = "Refuelled at " .. (translateLanguage(stationName, stationName, true))

  if businessCtx then
    -- Business fleet vehicle: bill the owning business account. Currently only
    -- Racing Team has a fuel debit helper; for any other biz type (or if the
    -- team account can't cover it) we fall back to the player's personal money
    -- so the pump transaction still completes.
    local paid = false
    if career_modules_business_racingTeamFinances and
       career_modules_business_racingTeamFinances.tryDebitVehicleFuelCost then
      paid = career_modules_business_racingTeamFinances.tryDebitVehicleFuelCost(
        businessCtx.businessId, overallPrice, stationLabel)
    end
    if paid then
      if overallPrice > 0 then
        ui_message("Fuel billed to the team account", 6, "refueling")
      end
      gameplay_statistic.metricAdd("career/fuel/paidPrice.money", overallPrice)
    else
      -- Fallback: team account unavailable / short. Charge the player instead
      -- so they aren't stuck at the pump.
      career_modules_playerAttributes.addAttributes({money = -overallPrice},
        {tags = {"fuel","buying"}, label = stationLabel})
      gameplay_statistic.metricAdd("career/fuel/paidPrice.money", overallPrice)
      if overallPrice > 0 then
        ui_message("Team account couldn't cover fuel; paid personally", 6, "refueling")
      end
    end
  else
    local invId = resolvePlayerInventoryId()
    local vehData = invId and career_modules_inventory.getVehicles()[invId]
    if vehData and vehData.loanType == "work" then
      ui_message(string.format("Fuel paid for by the company"), 6, "refueling")
    else
      career_modules_playerAttributes.addAttributes({money=-overallPrice}, {
        tags = {"fuel", "buying"},
        label = {
          txt = "ui.career.attributeLog.refuelledAt",
          context = { facilityName = gasStation.facility.name },
        },
      })
      gameplay_statistic.metricAdd("career/fuel/paidPrice.money", overallPrice)
    end
  end

  endTransaction()
  extensions.hook("onPaidRefuelling", overallPrice)
  gameplay_achievement.unlockAchievement("VEHICLE_REFUELLED")
end

local function uiSetSelectedTankIndex(index)
  if isCurrentlyFueling() then return end
  local validIndex = getValidTankIndex(index)
  if not validIndex then return end
  selectedTankIndex = validIndex
  defaultEnergyType = fuelData[selectedTankIndex].energyType
end

local function uiButtonStartFueling(energyType)
  startFuelingType(energyType)
end

local function uiButtonStopFueling(energyType)
  stopFuelingType(energyType)
end

local function uiButtonStartFuelingTank(index)
  uiSetSelectedTankIndex(index)
  local validIndex = getValidTankIndex(selectedTankIndex)
  if validIndex then
    startFuelingTank(validIndex)
    updateFuelingFlags()
    sendUpdateDataToUI()
  end
end

local function uiButtonStopFuelingTank(index)
  local validIndex = getValidTankIndex(index)
  if validIndex then
    stopFuelingTank(validIndex, false)
    updateFuelingFlags()
    applyFuelData()
  end
end

local function uiCancelTransaction()
  if fuelData then
    if startingFuelData then
      restoreFuelData(startingFuelData)
    end
    endTransaction()
  end
end

function isCurrentlyFueling()
  if fuelData then
    for index, data in ipairs(fuelData) do
      if fuelingActive[index] then
        return true
      end
    end
  end
  return false
end

local function updateOverallPrice()
  overallPrice = 0
  for _, data in ipairs(fuelingData) do
    overallPrice = overallPrice + data.price
  end
end

local function getFuelingEnergyRate(energyType)
  return energyType == "electricEnergy" and fuelFlowRate / 3 or fuelFlowRate
end

local uiFuelDataDeltaCounter = 0
local function onUpdate(dtReal, dtSim)
  if showUI then
    local veh = getFuelingVehicle()
    if veh and veh:getVelocity():length() > 2 then
      uiCancelTransaction()
    end
  end

  if fuelData then
    uiFuelDataDeltaCounter = uiFuelDataDeltaCounter + dtReal

    local applyAndSendToUI = false
    for index, data in ipairs(fuelData) do
      if fuelingActive[index] then
        data.currentEnergy = data.currentEnergy + dtSim * getFuelingEnergyRate(data.energyType)
        fuelingData[index].fueledEnergy = data.currentEnergy - startingFuelData[index].currentEnergy

        local price = getPricePerUnit(data.energyType) * jouleToReadableUnit(fuelingData[index].fueledEnergy, data.energyType)
        fuelingData[index].price = math.floor((price * 100) + 0.5) / 100
        if data.currentEnergy > data.maxEnergy then
          -- tank is full
          data.currentEnergy = data.maxEnergy
          stopFuelingTank(index, false)
          applyAndSendToUI = true
        end
      end
    end
    updateOverallPrice()

    if applyAndSendToUI then
      updateFuelingFlags()
      applyFuelData()
    elseif isCurrentlyFueling() then
      -- do a regular update for ui
      if uiFuelDataDeltaCounter > 0.1 then
        sendUpdateDataToUI()
        uiFuelDataDeltaCounter = 0
      end
    end
    if energyTypeFuelingActive["gasoline"] or energyTypeFuelingActive["diesel"] or energyTypeFuelingActive["kerosine"] then
      updateFuelSoundParameters()
    end
  end

  if showUI and not shipping_build then
    imgui.SetNextWindowSize(imgui.ImVec2(360, 520), imgui.Cond_FirstUseEver)
    imgui.Begin("Fueling")

    for index, tankData in ipairs(fuelData) do
      if imgui.BeginChild1("Tank " .. index, imgui.ImVec2(0, 175), true) then
        imgui.Text("Tank " .. index)
        imgui.Text(string.format("Fuel Type: %s", tankData.energyType))
        local unit = readableUnit[tankData.energyType]
        imgui.Text(string.format("Energy: %.2f %s / %.2f %s", jouleToReadableUnit(tankData.currentEnergy, tankData.energyType), unit, jouleToReadableUnit(tankData.maxEnergy, tankData.energyType), unit))
        imgui.Text(string.format("Fueled Energy: %.2f %s", jouleToReadableUnit(fuelingData[index].fueledEnergy, tankData.energyType) or 0, unit))
        imgui.Text(string.format("Fueling Active: %s", tostring(fuelingActive[index] == true)))
        imgui.Text(string.format("Fueling Speed: %.2f %s/s", fuelingActive[index] and jouleToReadableUnit(getFuelingEnergyRate(tankData.energyType), tankData.energyType) or 0, unit))

        imgui.Text("Price " .. fuelingData[index].price or 0)
      end
      imgui.EndChild()
    end

    local fuelFlowFactor = maxFuelFlowRate > 0 and fuelFlowRate / maxFuelFlowRate or 0
    imgui.Text(string.format("Fuel Flow Rate: %.0f J/s (%.2f)", fuelFlowRate, fuelFlowFactor))
    imgui.Text(string.format("Currently Fueling: %s", tostring(isCurrentlyFueling())))
    imgui.Text(string.format("Default Energy Type: %s", tostring(defaultEnergyType)))

    local _, _, relativeFuelLevel = getGasFuelLevelInfo()
    local gasSound = gasSoundId and scenetree.findObjectById(gasSoundId) or nil
    local electricSound = electricSoundId and scenetree.findObjectById(electricSoundId) or nil
    imgui.Separator()
    imgui.Text("Refueling Sound")
    imgui.Text(string.format("Gas active: %s", tostring(energyTypeFuelingActive["gasoline"] or energyTypeFuelingActive["diesel"] or energyTypeFuelingActive["kerosine"] or false)))
    imgui.Text(string.format("Gas sound id: %s", tostring(gasSoundId)))
    imgui.Text(string.format("Gas sound object: %s", gasSound and "found" or "missing"))
    imgui.Text(string.format("Gas playing flag: %s", tostring(isSoundPlaying[gasSoundId] == true)))
    imgui.Text(string.format("Gas volume param: %s", relativeFuelLevel and string.format("%.2f", relativeFuelLevel) or "n/a"))
    imgui.Text(string.format("Gas pitch param: %.2f", fuelFlowFactor))
    imgui.Text(string.format("Electric active: %s", tostring(energyTypeFuelingActive["electricEnergy"] or false)))
    imgui.Text(string.format("Electric sound id: %s", tostring(electricSoundId)))
    imgui.Text(string.format("Electric sound object: %s", electricSound and "found" or "missing"))
    imgui.Text(string.format("Electric playing flag: %s", tostring(isSoundPlaying[electricSoundId] == true)))

    for i, energyType in ipairs(energyTypes) do
      if imgui.Button(string.format("Start Fueling %s ##%d", energyType, i)) then
        uiButtonStartFueling(energyType)
      end
      imgui.SameLine()
      if imgui.Button(string.format("Stop Fueling %s ##%d", energyType, i)) then
        uiButtonStopFueling(energyType)
      end
    end

    imgui.Text(string.format("Overall Price: %.2f $", overallPrice))
    if overallPrice <= career_modules_playerAttributes.getAttributeValue("money") then
      if imgui.Button(string.format("Pay")) then
        payPrice()
      end
    else
      imgui.Text("Not enough money to pay")
    end
    imgui.End()
  end
end

local function setMinimumFuel(data, veh)
  local tanksData = data[1]
  for i, tank in ipairs(tanksData) do
    -- refuel the car if it is electric or nearly empty
    if tank.energyType == "electricEnergy" then
      tank.currentEnergy = tank.maxEnergy
      ui_message("Your vehicle has been fully recharged", nil, "emergencyRefuel")
    elseif tank.currentEnergy <= tank.maxEnergy * 0.01 then
      tank.currentEnergy = tank.maxEnergy * 0.05
      ui_message("Your tank was close to empty, so it has been refueled a little bit. You should visit a fuel station", nil, "emergencyRefuel")
    end
  end
  applyFuelData(tanksData, veh)
end

local function minimumRefuelingCheck(vehId)
  if not vehId then
    local invId = resolvePlayerInventoryId()
    vehId = invId and career_modules_inventory.getVehicleIdFromInventoryId(invId)
  end
  if vehId and gameplay_offroadRecovery and gameplay_offroadRecovery.isContractTarget
      and gameplay_offroadRecovery.isContractTarget(vehId) then
    return
  end
  if vehId then
    local veh = getObjectByID(vehId)
    if veh then
      core_vehicleBridge.requestValue(veh, function(data) setMinimumFuel(data, veh) end, 'energyStorage')
    end
  end
end

local function setupSounds()
  gasSoundId = gasSoundId or Engine.Audio.createSource('AudioGui', 'event:>UI>Career>Fueling_Petrol')
  electricSoundId = electricSoundId or Engine.Audio.createSource('AudioGui', 'event:>UI>Career>Fueling_Electric')
end

local function onCareerActive(active)
  if not active then return end
  setupSounds()
end

local function onClientEndMission(levelPath)
  gasSoundId = nil
  electricSoundId = nil
end

-- Shop-stockpile refueling for Racing Team "Pit Fuel" skill: kick off a
-- refueling transaction against a synthetic gas station, billing the team
-- account at the current average regional price. Returns true on success, or
-- (false, reasonCode) if the vehicle can't be refueled right now.
local function startForBusinessVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false, "invalidArgs"
  end
  if not career_modules_business_businessInventory then
    return false, "noInventory"
  end

  local spawnedId = career_modules_business_businessInventory.getSpawnedVehicleId and
    career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
  if not spawnedId then
    return false, "notPulledOut"
  end
  local vehObj = getObjectByID(spawnedId)
  if not vehObj then
    return false, "notPulledOut"
  end

  -- Focus/enter the biz vehicle so getPlayerVehicle(0) returns it for the
  -- duration of the refueling dialog.
  be:enterVehicle(0, vehObj)

  businessCtx = {
    businessId = businessId,
    vehicleId = vehicleId,
    vehObjId = spawnedId,
  }
  pendingBizReturn = {
    businessId = businessId,
    businessType = "racingTeam",
  }

  local syntheticStation = {
    facility = {
      id = SHOP_STATION_ID,
      name = "Shop Stockpile",
    },
  }
  startTransaction(syntheticStation)
  return true
end

M.startTransaction = startTransaction
M.startForBusinessVehicle = startForBusinessVehicle
M.getFuelData = getFuelData
M.isCurrentlyFueling = isCurrentlyFueling
M.getFuelingData = getFuelingData
M.payPrice = payPrice
M.onChangeFlowRate = onChangeFlowRate

-- Called by UI
M.uiButtonStartFueling = uiButtonStartFueling
M.uiButtonStopFueling = uiButtonStopFueling
M.uiButtonStartFuelingTank = uiButtonStartFuelingTank
M.uiButtonStopFuelingTank = uiButtonStopFuelingTank
M.uiSetSelectedTankIndex = uiSetSelectedTankIndex
M.requestRefuelingTransactionData = requestRefuelingTransactionData
M.uiCancelTransaction = uiCancelTransaction
M.sendUpdateDataToUI = sendUpdateDataToUI

M.onUpdate = onUpdate
M.onCareerActive = onCareerActive
M.onClientEndMission = onClientEndMission
M.minimumRefuelingCheck = minimumRefuelingCheck

return M
