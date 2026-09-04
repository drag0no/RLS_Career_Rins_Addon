local M = {}

M.dependencies = {'career_modules_valueCalculator', 'career_modules_inventory', 'career_modules_playerAttributes', 'career_modules_payment', 'career_modules_insurance_insurance', 'career_modules_tether'}

local originComputerId
local vehicleToRepairData
local tether
local tetherRange = 7 -- meters
local roadsideMode = false
local roadsideTetherRange = 14 -- meters
local CONVENIENCE_FEE_MULT = 1.15
local getRepairData

local function applyConvenienceFee(amount)
  amount = tonumber(amount) or 0
  return math.ceil(amount * CONVENIENCE_FEE_MULT)
end

-- Roadside is instant-only. Always emit a real sequential array so Vue's
-- Array.prototype.find / .length work (empty {} or dict-keyed tables break the UI).
local function keepInstantRepairChoices(repairTimeOptions, fallbackChoice)
  if not repairTimeOptions then
    return
  end

  local instant = nil
  for _, choiceData in pairs(repairTimeOptions.choices or {}) do
    if type(choiceData) == "table" and tonumber(choiceData.value) == 0 then
      instant = deepcopy(choiceData)
      break
    end
  end

  if not instant then
    instant = deepcopy(fallbackChoice) or {
      id = 1,
      value = 0,
      premiumInfluence = 0,
      choiceText = _tr("ui.career.insurance.coverageChoice.instant"),
      totalPrice = 0,
      canPay = true,
    }
  end

  instant.id = instant.id or 1
  instant.value = 0
  instant.disabled = false
  instant.canPay = instant.canPay ~= false

  repairTimeOptions.choiceType = "multiple"
  repairTimeOptions.key = repairTimeOptions.key or "repairTime"
  repairTimeOptions.choices = { instant }
  repairTimeOptions.currentValueId = instant.id
end

local function hideRoadsidePopup()
  guihooks.trigger("roadsideRepairPopup", { visible = false })
end

local function closeRoadsidePopup()
  roadsideMode = false
  if tether then
    tether.remove = true
    tether = nil
  end
  hideRoadsidePopup()
end

local function getInstantChoice(repairTimeOptions)
  local choices = repairTimeOptions and repairTimeOptions.choices
  if type(choices) ~= "table" then
    return nil
  end
  return choices[1]
end

local function buildRoadsidePopupPayload()
  local data = getRepairData()
  if not data then
    return { visible = false }
  end
  local privateChoice = getInstantChoice(data.repairOptions.noInsuranceRepairData.repairTimeOptions)
  local privatePrice = privateChoice and privateChoice.totalPrice or data.vehicleData.damageCost

  local payload = {
    visible = true,
    vehicleName = data.vehicleData.name,
    invVehId = data.vehicleData.invVehId,
    private = {
      price = privatePrice,
      canPay = career_modules_payment.canPay({ money = { amount = privatePrice, canBeNegative = false } }),
      repairTimeCost = privateChoice and privateChoice.premiumInfluence or 0,
      damageCost = data.vehicleData.damageCost,
    },
  }

  local insuranceData = data.repairOptions.insuranceRepairData
  if insuranceData then
    local insuranceChoice = getInstantChoice(insuranceData.repairTimeOptions)
    local insurancePrice = insuranceChoice and insuranceChoice.totalPrice or insuranceData.deductible
    payload.insurance = {
      price = insurancePrice,
      canPay = career_modules_payment.canPay({ money = { amount = insurancePrice, canBeNegative = false } }),
      repairTimeCost = insuranceChoice and (insuranceChoice.premiumInfluence or 0) or 0,
      deductible = insuranceData.deductible,
    }
  end

  return payload
end

local function openRepairMenu(vehicle, _originComputerId, options)
  options = options or {}
  vehicleToRepairData = vehicle
  originComputerId = _originComputerId
  roadsideMode = options.roadside == true

  tether = nil
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    if computer then
      local door = computer.doors and computer.doors[1]
      if door then
        tether = career_modules_tether.startDoorTether(door, tetherRange, career_career.closeAllMenus)
      end
      if not tether then
        tether = career_modules_tether.startSphereTether(freeroam_facilities.getAverageDoorPositionForFacility(computer), tetherRange, career_career.closeAllMenus)
      end
    end
  end

  extensions.ui_router.navigate("career.computer.repair")
end

local function openRoadsideRepairMenu(vehicle)
  vehicleToRepairData = vehicle
  originComputerId = nil
  roadsideMode = true

  if tether then
    tether.remove = true
    tether = nil
  end

  local veh = be:getPlayerVehicle(0)
  if veh then
    tether = career_modules_tether.startSphereTether(veh:getPosition(), roadsideTetherRange, closeRoadsidePopup)
  end

  guihooks.trigger("roadsideRepairPopup", buildRoadsidePopupPayload())
end

local function closeRepairMenu()
  if roadsideMode and not originComputerId then
    closeRoadsidePopup()
    return
  end
  roadsideMode = false
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleInventory"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "repair",
      routeTarget = "career.computer.repair",
      label = _tr("ui.career.shared.pathRepair"),
      callback = function() openRepairMenu(career_modules_inventory.getVehicles()[inventoryId], menuData.computerFacility.id) end,
      order = 5
    }

    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
    end

    local reason = career_modules_permissions.getStatusForTag({"vehicleRepair"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

local function getClaimCostsPreview(invVehInfo, insuranceModule)
  return {deductible = insuranceModule.getPlCoverageOptionValue(invVehInfo.id, "deductible")}
end

local function getFutureDriverScoreAfterClaim(insuranceId, insuranceModule, invVehInfo)
  local plInsurancesData = insuranceModule.getPlayerInsurancesData()
  local plDriverScore = insuranceModule.getDriverScore()
  if insuranceId and plInsurancesData[insuranceId] and plInsurancesData[insuranceId].accidentForgiveness > 0 then
    return plDriverScore
  end
  local penalty = insuranceModule.getInsuranceRepairDriverScorePenalty(invVehInfo, getClaimCostsPreview(invVehInfo, insuranceModule))
  return math.max(plDriverScore - penalty, 0)
end

local function getFuturePremiumAfterClaim(insuranceId, insuranceModule, invVehInfo)
  local plInsurancesData = insuranceModule.getPlayerInsurancesData()
  local plDriverScore = insuranceModule.getDriverScore()

  if not insuranceId or not plInsurancesData[insuranceId] then return 0 end
  if plInsurancesData[insuranceId].accidentForgiveness > 0 then
    return insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore
  end
  local penalty = insuranceModule.getInsuranceRepairDriverScorePenalty(invVehInfo, getClaimCostsPreview(invVehInfo, insuranceModule))
  local futureScore = math.max(plDriverScore - penalty, 0)
  local futureTierData = insuranceModule.getDriverScoreTierData(futureScore)
  return insuranceModule.calculateInsurancePremium(insuranceId).totalPrice * futureTierData.multiplier
end

getRepairData = function()
  local insuranceModule = career_modules_insurance_insurance
  local invVehs = insuranceModule.getInvVehs()
  local invVehInfo = deepcopy(vehicleToRepairData)
  local invVehInsurance = invVehs and invVehs[invVehInfo.id]
  if not invVehInsurance and invVehs then
    invVehInsurance = invVehs[tostring(invVehInfo.id)]
  end
  if not invVehInsurance then
    log("E", "career.insurance.repairScreen", string.format("Missing invVehs entry for vehicle %s", tostring(invVehInfo.id)))
    return nil
  end
  local insuranceId = invVehInsurance.insuranceId

  local damageCost = career_modules_valueCalculator.getRepairDetails(invVehInfo).price
  if roadsideMode then
    damageCost = applyConvenienceFee(damageCost)
  end

  local data = {
    repairOptions = {
      noInsuranceRepairData = {
        repairTimeOptions = {},
        useInsurance = false,
      },
      insuranceRepairData = nil,
    },
    vehicleData = {
      damageCost = damageCost,
      name = career_modules_inventory.getVehicleNiceNameTranslated(invVehInfo.id),
      initialValue = invVehInsurance.initialValue,
      invVehId = invVehInfo.id,
      thumbnail = (career_modules_inventory.getVehicleThumbnail(invVehInfo.id) or "") .. "?" .. (invVehInfo.dirtyDate or ""),
      isInsured = (insuranceId or -1) > 0,
      needsRepair = true,
      roadside = roadsideMode,
    },
    playerAttributes = career_modules_playerAttributes.getAllAttributes(),
    driverScoreTierData = insuranceModule.getDriverScoreTierData(),
    futureDriverScore = getFutureDriverScoreAfterClaim(insuranceId, insuranceModule, invVehInfo),
    driverScore = insuranceModule.getDriverScore(),
    roadside = roadsideMode,
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    local deductible = insuranceModule.getPlCoverageOptionValue(invVehInfo.id, "deductible")
    if roadsideMode then
      deductible = applyConvenienceFee(deductible)
    end
    data.repairOptions.insuranceRepairData = {
      repairTimeOptions = {},
      useInsurance = true,
      renewsIn = insuranceModule.getRenewsIn(insuranceId),
      insuranceName = insuranceModule.getInsuranceName(insuranceId),
      currentPremium = insuranceModule.calculateInsurancePremium(insuranceId).totalPriceWithDriverScore,
      futurePremium = getFuturePremiumAfterClaim(insuranceId, insuranceModule, invVehInfo),
      deductible = deductible,
      accidentForgivenesses = insuranceModule.getAccidentForgivenessCount(insuranceId),
    }
  end

  local defaultRepairTimeChoiceData
  if insuranceModule.doesInsuranceExist(insuranceId) then
    defaultRepairTimeChoiceData = insuranceModule.sanitizeCoverageOption(insuranceId, "repairTime", invVehInfo.id)
    data.repairOptions.insuranceRepairData.repairTimeOptions = deepcopy(defaultRepairTimeChoiceData)
  end

  data.repairOptions.noInsuranceRepairData.repairTimeOptions = {
    name = _tr("insurance.perks.repairTime.name", "Repair time"),
    choiceType = "multiple",
    choices = {
      {id = 1, value = 0, premiumInfluence = roadsideMode and applyConvenienceFee(500) or 500, choiceText = _tr("ui.career.insurance.coverageChoice.instant")},
      {id = 2, value = 120, premiumInfluence = 350, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 2})},
      {id = 3, value = 300, premiumInfluence = 150, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 5})},
      {id = 4, value = 600, premiumInfluence = 50, choiceText = core_locales.contextTranslate("ui.career.insurance.coverageChoice.minutes", {count = 10})}
    },
    currentValueId = 1,
  }

  if insuranceModule.doesInsuranceExist(insuranceId) then
    for _, choiceData in pairs(data.repairOptions.insuranceRepairData.repairTimeOptions.choices) do
      if roadsideMode and choiceData.premiumInfluence then
        choiceData.premiumInfluence = applyConvenienceFee(choiceData.premiumInfluence)
      end
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId then
        choiceData.totalPrice = data.repairOptions.insuranceRepairData.deductible
        choiceData.premiumInfluence = 0
        local hasFreeInstantRepairPerk = insuranceModule.getPerkValueByInsuranceId(insuranceId, "instantRepair")
        choiceData.secondaryText = hasFreeInstantRepairPerk and _tr("ui.career.repair.freePolicyPerk") or _tr("ui.career.repair.alreadyPaidPolicyCoverage")
        data.repairOptions.noInsuranceRepairData.repairTimeOptions.currentValueId = choiceData.id
      elseif choiceData.value == 0 then
        choiceData.totalPrice = choiceData.premiumInfluence + data.repairOptions.insuranceRepairData.deductible
      end
      if choiceData.id == defaultRepairTimeChoiceData.currentValueId or choiceData.value == 0 then
        choiceData.canPay = true
        choiceData.repairTimePrice = choiceData.premiumInfluence
        choiceData.disabled = false
      else
        choiceData.disabled = true
      end
    end
  end

  for _, choiceData in pairs(data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices) do
    local totalPrice = choiceData.premiumInfluence + data.vehicleData.damageCost
    local canPay = career_modules_payment.canPay({money = {amount = totalPrice, canBeNegative = false}})
    choiceData.totalPrice = totalPrice
    choiceData.canPay = canPay
    choiceData.repairTimePrice = choiceData.oldPremiumInfluence and choiceData.oldPremiumInfluence or choiceData.premiumInfluence
  end

  if roadsideMode then
    local privateInstant = data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices
      and data.repairOptions.noInsuranceRepairData.repairTimeOptions.choices[1]
    keepInstantRepairChoices(data.repairOptions.noInsuranceRepairData.repairTimeOptions, privateInstant)
    if data.repairOptions.insuranceRepairData then
      keepInstantRepairChoices(data.repairOptions.insuranceRepairData.repairTimeOptions, {
        id = 1,
        value = 0,
        premiumInfluence = 0,
        choiceText = _tr("ui.career.insurance.coverageChoice.instant"),
        totalPrice = data.repairOptions.insuranceRepairData.deductible,
        canPay = true,
        repairTimePrice = 0,
      })
    end
  end

  return data
end

local function onMenuClosed()
  if roadsideMode and not originComputerId then
    closeRoadsidePopup()
    return
  end
  roadsideMode = false
  if tether then tether.remove = true tether = nil end
end

local function closeMenu()
  closeRepairMenu()
end

local function startRepairAtRoadside(invVehId, repairOptionData)
  repairOptionData = repairOptionData or {}
  repairOptionData.repairTime = 0

  -- Fee is already baked into the prices shown by getRepairData when roadsideMode is on.
  if tether then tether.remove = true tether = nil end
  roadsideMode = false
  hideRoadsidePopup()
  return career_modules_insurance_insurance.startRepairInPlace(invVehId, repairOptionData, function()
    career_career.closeAllMenus()
  end)
end

local function startRepairInGarage(invVehId, repairOptionData)
  if roadsideMode then
    return startRepairAtRoadside(invVehId, repairOptionData)
  end

  -- Despawn / start repair before reopening the computer so vehiclesInGarage is current.
  if tether then tether.remove = true tether = nil end
  local computer = originComputerId and freeroam_facilities.getFacility("computer", originComputerId)
  local result = career_modules_insurance_insurance.startRepairInGarage(invVehId, repairOptionData)
  if computer then
    career_modules_computer.openMenu(computer, true)
  else
    career_career.closeAllMenus()
  end
  return result
end

M.getRepairData = getRepairData
M.openRepairMenu = openRepairMenu
M.openRoadsideRepairMenu = openRoadsideRepairMenu
M.closeRepairMenu = closeRepairMenu
M.closeRoadsidePopup = closeRoadsidePopup
M.closeMenu = closeMenu
M.startRepairInGarage = startRepairInGarage
M.isRoadsideMode = function() return roadsideMode end

M.onComputerAddFunctions = onComputerAddFunctions
M.onMenuClosed = onMenuClosed

return M
