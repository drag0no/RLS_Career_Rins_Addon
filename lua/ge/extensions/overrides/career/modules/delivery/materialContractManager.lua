-- Predetermined, multi-load bulk material hauling contracts.
local M = {}

local sharedCalc = require('gameplay/delivery/calculators')
local xpConfig = require('gameplay/delivery/logisticsXPConfig')

local dGenerator, dGeneral, dParcelManager, dCargoScreen
local state = {
  offersByFacility = {},
  nextRefillByFacility = {},
  activeContracts = {},
  nextContractId = 1,
  storageModelVersion = 2,
  contractStateVersion = 2,
}
local initialized = false
local updateAccumulator = 0
local taskGuidanceVisible = {}
local lastTaskGuidanceSignatures = {}
local legacyMaterialTaskId = "material-contract-active"

local function materialTaskId(contractId)
  return "material-contract-active-" .. tostring(contractId)
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function rules()
  return xpConfig.getMaterialContractRules()
end

local function now()
  return dGeneral and dGeneral.time and dGeneral.time() or 0
end

local function roundReward(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

local function getStandardLoad(materialType, materialData)
  local cfg = rules()
  local materialOverride = cfg.standardLoadByMaterial[materialType]
  if materialOverride then return materialOverride end
  local cargoType = materialData and materialData.type or materialType
  return cfg.standardLoadByType[cargoType] or 1
end
M.getStandardLoad = getStandardLoad

local function getLoadRange(materialType, materialData)
  local cfg = rules()
  if materialType == "cash" or materialType == "coin" or materialType == "gold" then
    return cfg.secureLoadCount.min, cfg.secureLoadCount.max
  end
  return cfg.bulkLoadCount.min, cfg.bulkLoadCount.max
end
M.getLoadRange = getLoadRange

local function findAccessPoint(facility, materialType, lookupKey, preferredName)
  if not facility then return nil end
  if preferredName and facility.accessPointsByName and facility.accessPointsByName[preferredName] then
    local preferred = facility.accessPointsByName[preferredName]
    if preferred[lookupKey] and preferred[lookupKey][materialType] then return preferred end
  end
  for _, name in ipairs(sortedKeys(facility.accessPointsByName)) do
    local accessPoint = facility.accessPointsByName[name]
    if accessPoint and accessPoint[lookupKey] and accessPoint[lookupKey][materialType] then
      return accessPoint
    end
  end
  return nil
end

local function locationForAccessPoint(facility, accessPoint)
  if not facility or not accessPoint then return nil end
  local path = accessPoint.psPath
  if not path and accessPoint.ps and accessPoint.ps.getPath then path = accessPoint.ps:getPath() end
  if not path then return nil end
  return {type = "facilityParkingspot", facId = facility.id, psPath = path}
end

local function getStorage(facId, materialType)
  local fac = dGenerator and dGenerator.getFacilityById and dGenerator.getFacilityById(facId)
  return fac, fac and fac.materialStorages and fac.materialStorages[materialType]
end

local function getLogisticsMoneyBonusMultiplier()
  local levelRules = xpConfig.getLevelBonusRules() or {}
  local perLevel = tonumber(levelRules.moneyPercentPerLevel) or 0
  if perLevel <= 0 or not career_branches then return 0 end
  local level = career_branches.getBranchLevel("logistics-delivery")
  if type(level) ~= "number" then level = career_branches.getBranchLevel("logistics") or 0 end
  return perLevel * math.max(0, level - 1)
end

local function applyMoneyDifficulty(money)
  local value = math.max(0, roundReward(money))
  if not (career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData) then
    return value
  end
  local rewardData = {money = {amount = value, canBeNegative = false}}
  career_modules_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = true})
  return math.max(0, roundReward(rewardData.money and rewardData.money.amount or value))
end

local function getOrganizationMoneyMultiplier(organization)
  if not organization or not freeroam_organizations or not freeroam_organizations.getOrganization then return 1 end
  local data = freeroam_organizations.getOrganization(organization)
  local level = data and data.reputation and tonumber(data.reputation.level) or 0
  local levelData = data and data.reputationLevels and data.reputationLevels[level + 2]
  return math.max(0, tonumber(levelData and levelData.deliveryBonus and levelData.deliveryBonus.value) or 1)
end

local function buildQuotedRewards(materialData, materialType, amount, distance, organization)
  local baseMoney = sharedCalc.getMaterialReward(materialData, amount).money
  local organizationMultiplier = getOrganizationMoneyMultiplier(organization)
  local ok, quoted = pcall(sharedCalc.getMaterialXPReward, distance, amount, organization, organizationMultiplier, nil, baseMoney, materialData.type)
  if not ok or type(quoted) ~= "table" then
    quoted = sharedCalc.getMaterialReward(materialData, amount, distance)
  end

  -- The shared calculator exposes a legacy alias and the canonical skill key.
  -- Keep only the canonical value so normalization cannot double-award XP.
  if quoted["logistics-delivery"] ~= nil then quoted.logistics = nil end

  quoted.money = applyMoneyDifficulty(quoted.money or sharedCalc.getMaterialReward(materialData, amount, distance).money)
  local levelMultiplier = getLogisticsMoneyBonusMultiplier()
  if levelMultiplier > 0 then
    quoted.money = quoted.money + roundReward(quoted.money * levelMultiplier)
  end
  for key, value in pairs(quoted) do quoted[key] = roundReward(value) end
  return quoted
end

local function existingPairLookup(facId)
  local used = {}
  for _, offer in ipairs(state.offersByFacility[facId] or {}) do
    used[string.format("%s|%s", offer.materialType, offer.destination.facId)] = true
  end
  return used
end

local function buildCandidates(sourceFac)
  local candidates = {}
  local usedPairs = existingPairLookup(sourceFac.id)
  for _, materialType in ipairs(sortedKeys(sourceFac.materialStorages)) do
    local sourceStorage = sourceFac.materialStorages[materialType]
    local materialData = dGenerator.getMaterialsTemplatesById(materialType)
    if sourceStorage and sourceStorage.isProvider and materialData then
      local originAp = findAccessPoint(sourceFac, materialType, "logisticTypesProvidedLookup", sourceStorage.pickUpSpotName)
      local origin = locationForAccessPoint(sourceFac, originAp)
      if origin then
        local standardLoad = getStandardLoad(materialType, materialData)
        local minLoads, maxLoads = getLoadRange(materialType, materialData)
        for _, destinationFac in ipairs(dGenerator.getFacilities() or {}) do
          local destinationStorage = destinationFac.materialStorages and destinationFac.materialStorages[materialType]
          local pairKey = string.format("%s|%s", materialType, destinationFac.id)
          if destinationFac.id ~= sourceFac.id and destinationStorage and destinationStorage.isReceiver and not usedPairs[pairKey] then
            local destinationAp = findAccessPoint(destinationFac, materialType, "logisticTypesReceivedLookup")
            local destination = locationForAccessPoint(destinationFac, destinationAp)
            if destination then
              local distance = dGenerator.getDistanceBetweenFacilities(origin, destination)
              if distance and distance >= 0 then
                candidates[#candidates + 1] = {
                  sourceFac = sourceFac,
                  sourceStorage = sourceStorage,
                  destinationFac = destinationFac,
                  destinationStorage = destinationStorage,
                  materialType = materialType,
                  materialData = materialData,
                  origin = origin,
                  destination = destination,
                  standardLoad = standardLoad,
                  minLoads = minLoads,
                  maxLoads = maxLoads,
                  distance = distance,
                }
              end
            end
          end
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.materialType ~= b.materialType then return a.materialType < b.materialType end
    return a.destination.facId < b.destination.facId
  end)
  return candidates
end

local function chooseDistanceDiverseCandidate(candidates, existingCount)
  if #candidates == 0 then return nil end
  local desiredBand = (existingCount % 3) + 1
  local band = {}
  for index, candidate in ipairs(candidates) do
    local candidateBand = math.min(3, math.floor((index - 1) * 3 / #candidates) + 1)
    if candidateBand == desiredBand then band[#band + 1] = candidate end
  end
  local pool = #band > 0 and band or candidates
  return pool[math.random(1, #pool)]
end

local function generateOfferForFacility(facId)
  if not initialized then return nil end
  local fac = dGenerator.getFacilityById(facId)
  if not fac then return nil end
  state.offersByFacility[facId] = state.offersByFacility[facId] or {}
  local offers = state.offersByFacility[facId]
  if #offers >= rules().maxOffersPerFacility then return nil end

  local candidate = chooseDistanceDiverseCandidate(buildCandidates(fac), #offers)
  if not candidate then return nil end
  local loadCount = math.random(candidate.minLoads, candidate.maxLoads)
  local totalAmount = candidate.standardLoad * loadCount
  local id = string.format("material-contract-%d", state.nextContractId)
  state.nextContractId = state.nextContractId + 1
  local quotedRewards = buildQuotedRewards(candidate.materialData, candidate.materialType, totalAmount, candidate.distance, fac.associatedOrganization)
  local createdAt = now()
  local offer = {
    id = id,
    status = "available",
    createdAt = createdAt,
    offerExpiresAt = createdAt + rules().offerDuration,
    sourceFacId = fac.id,
    sourceName = fac.name,
    destinationFacId = candidate.destinationFac.id,
    destinationName = candidate.destinationFac.name,
    origin = deepcopy(candidate.origin),
    destination = deepcopy(candidate.destination),
    materialType = candidate.materialType,
    materialName = candidate.materialData.name,
    cargoType = candidate.materialData.type,
    units = candidate.materialData.units or "L",
    density = candidate.materialData.density,
    standardLoad = candidate.standardLoad,
    loadCount = loadCount,
    totalAmount = totalAmount,
    routeDistance = candidate.distance,
    routeFactor = sharedCalc.getMaterialRouteFactor(candidate.distance),
    quotedRewards = quotedRewards,
    organization = fac.associatedOrganization,
    usesVirtualStorage = true,
  }
  offers[#offers + 1] = offer
  return offer
end
M.generateOfferForFacility = generateOfferForFacility

local function expireOffersForFacility(facId)
  local currentTime = now()
  local kept = {}
  local changed = false
  for _, offer in ipairs(state.offersByFacility[facId] or {}) do
    if offer.offerExpiresAt and offer.offerExpiresAt > currentTime then
      kept[#kept + 1] = offer
    else
      changed = true
    end
  end
  state.offersByFacility[facId] = kept
  return changed
end

local function notifyChanged()
  if guihooks then
    guihooks.trigger("materialContractsChanged", M.getUiState())
    guihooks.trigger("requestCargoDataSimple")
  end
end

local function seedFacility(facId, amount)
  state.offersByFacility[facId] = state.offersByFacility[facId] or {}
  while #state.offersByFacility[facId] < amount do
    if not generateOfferForFacility(facId) then break end
  end
end

local function setup(savedState)
  local restoringContractState = type(savedState) == "table" and savedState.offersByFacility ~= nil
  state = {
    offersByFacility = {},
    nextRefillByFacility = {},
    activeContracts = {},
    nextContractId = 1,
    storageModelVersion = 2,
    contractStateVersion = 2,
  }
  local savedStorageModelVersion = type(savedState) == "table" and tonumber(savedState.storageModelVersion) or 1
  if type(savedState) == "table" then
    state.offersByFacility = deepcopy(savedState.offersByFacility or {})
    state.nextRefillByFacility = deepcopy(savedState.nextRefillByFacility or {})
    state.nextContractId = math.max(1, math.floor(tonumber(savedState.nextContractId) or 1))
    for _, offers in pairs(state.offersByFacility) do
      for _, offer in ipairs(offers) do offer.usesVirtualStorage = true end
    end

    local savedActiveContracts = savedState.activeContracts
    if type(savedActiveContracts) == "table" then
      for key, savedContract in pairs(savedActiveContracts) do
        if type(savedContract) == "table" then
          local contract = deepcopy(savedContract)
          contract.id = contract.id or tostring(key)
          state.activeContracts[contract.id] = contract
        end
      end
    end
    -- v1 stored one singleton. Wrap it without losing accepted time, partial
    -- rewards, or the pre-virtual-storage migration below.
    if type(savedState.activeContract) == "table" and savedState.activeContract.id
      and not state.activeContracts[savedState.activeContract.id] then
      state.activeContracts[savedState.activeContract.id] = deepcopy(savedState.activeContract)
    end
  end

  -- Pre-v2 contracts physically removed their full quantity from the source
  -- and added delivered loads to the receiver. Return that accounting once;
  -- project supply and project consumption are virtual from v2 onward.
  for contractId, contract in pairs(state.activeContracts) do
    contract.deliveredAmount = math.max(0, tonumber(contract.deliveredAmount) or 0)
    contract.paidRewards = contract.paidRewards or {}
    contract.status = contract.status == "completed" and "completed" or "active"
    if contract.deliveredAmount >= (contract.totalAmount or math.huge) then
      state.activeContracts[contractId] = nil
    else
      if savedStorageModelVersion < 2 and not contract.usesVirtualStorage then
        local _, sourceStorage = getStorage(contract.sourceFacId, contract.materialType)
        local _, destinationStorage = getStorage(contract.destinationFacId, contract.materialType)
        if sourceStorage then
          sourceStorage.storedVolume = math.min(sourceStorage.capacity or math.huge,
            (sourceStorage.storedVolume or 0) + (contract.totalAmount or 0))
        end
        if destinationStorage then
          destinationStorage.storedVolume = math.max(0,
            (destinationStorage.storedVolume or 0) - (contract.deliveredAmount or 0))
        end
      end
      contract.usesVirtualStorage = true
    end
  end
  initialized = true

  local currentTime = now()
  for _, fac in ipairs(dGenerator.getFacilities() or {}) do
    local hasProvider = false
    for _, storage in pairs(fac.materialStorages or {}) do
      if storage.isProvider then hasProvider = true break end
    end
    if hasProvider then
      state.offersByFacility[fac.id] = state.offersByFacility[fac.id] or {}
      expireOffersForFacility(fac.id)
      if not restoringContractState and #state.offersByFacility[fac.id] == 0 then
        seedFacility(fac.id, rules().initialOffersPerFacility)
      end
      state.nextRefillByFacility[fac.id] = tonumber(state.nextRefillByFacility[fac.id]) or (currentTime + rules().refillInterval)
    end
  end
end
M.setup = setup

local function serialize()
  return deepcopy(state)
end
M.serialize = serialize

local function getOffersForFacility(facId)
  if not initialized then return {} end
  expireOffersForFacility(facId)
  return deepcopy(state.offersByFacility[facId] or {})
end
M.getOffersForFacility = getOffersForFacility

local function getAllOffers()
  local result = {}
  if not initialized then return result end
  for _, facId in ipairs(sortedKeys(state.offersByFacility)) do
    for _, offer in ipairs(getOffersForFacility(facId)) do result[#result + 1] = offer end
  end
  return result
end
M.getAllOffers = getAllOffers

local function findOffer(offerId)
  for facId, offers in pairs(state.offersByFacility) do
    for index, offer in ipairs(offers) do
      if offer.id == offerId then return offer, facId, index end
    end
  end
  return nil
end

local function sortedActiveContracts()
  local result = {}
  for _, contract in pairs(state.activeContracts or {}) do result[#result + 1] = contract end
  table.sort(result, function(a, b)
    local aAccepted = tonumber(a.acceptedAt) or 0
    local bAccepted = tonumber(b.acceptedAt) or 0
    if aAccepted ~= bAccepted then return aAccepted < bAccepted end
    return tostring(a.id) < tostring(b.id)
  end)
  return result
end

local function activeCargoAmounts(contractId)
  local active = state.activeContracts[contractId]
  if not active or not dParcelManager then return 0, 0 end
  local inTransit, pending = 0, 0
  for _, cargo in ipairs(dParcelManager.getAllCargoCustomFilter(function(cargo)
    return cargo.data and cargo.data.materialContractId == active.id and cargo.location and cargo.location.type ~= "deleted"
  end) or {}) do
    if cargo.location.type == "vehicle" then
      inTransit = inTransit + (tonumber(cargo.slots) or 0)
    elseif cargo._transientMove and cargo._transientMove.targetLocation and cargo._transientMove.targetLocation.type == "vehicle" then
      pending = pending + (tonumber(cargo.slots) or 0)
    end
  end
  return inTransit, pending
end
M.getActiveCargoAmounts = activeCargoAmounts

local function snapshotContract(contractId)
  local active = state.activeContracts[contractId]
  if not active then return nil end
  local result = deepcopy(active)
  local inTransit, pending = activeCargoAmounts(contractId)
  result.inTransitAmount = inTransit
  result.pendingLoadAmount = pending
  result.remainingAmount = math.max(0, result.totalAmount - (result.deliveredAmount or 0))
  result.loadableAmount = math.max(0, result.remainingAmount - inTransit - pending)
  result.sourceReservedAmount = math.max(0, result.remainingAmount - inTransit)
  result.receiverReservedAmount = result.remainingAmount
  result.paidMoney = (result.paidRewards and result.paidRewards.money) or 0
  result.remainingValue = math.max(0, (result.quotedRewards.money or 0) - result.paidMoney)
  result.abandonmentFine = roundReward(result.remainingValue * rules().abandonPenaltyFactor)
  return result
end

local function getActiveContracts()
  local result = {}
  for _, contract in ipairs(sortedActiveContracts()) do
    result[#result + 1] = snapshotContract(contract.id)
  end
  return result
end
M.getActiveContracts = getActiveContracts
M.getContractById = snapshotContract
M.getActiveContract = snapshotContract

local function sameContractLocation(a, b)
  if not a or not b then return false end
  if dParcelManager and dParcelManager.sameLocation then
    return dParcelManager.sameLocation(a, b)
  end
  return a.type == b.type and a.facId == b.facId and a.psPath == b.psPath
end

-- Bulk material is fungible once it is in a player's container. The contract
-- used at pickup reserves how much may be loaded, but every active contract for
-- that exact material may consume it at its own receiver.
local function getContractsAcceptingMaterial(materialType, location)
  local result = {}
  for _, contract in ipairs(sortedActiveContracts()) do
    local remaining = math.max(0, (tonumber(contract.totalAmount) or 0) - (tonumber(contract.deliveredAmount) or 0))
    if contract.status == "active" and contract.materialType == materialType and remaining > 0
      and (not location or sameContractLocation(contract.destination, location)) then
      local accepting = deepcopy(contract)
      accepting.remainingAmount = remaining
      result[#result + 1] = accepting
    end
  end
  return result
end
M.getContractsAcceptingMaterial = getContractsAcceptingMaterial

local function getMaterialDeliveryCapacity(materialType, location)
  local capacity = 0
  for _, contract in ipairs(getContractsAcceptingMaterial(materialType, location)) do
    capacity = capacity + math.max(0, tonumber(contract.remainingAmount) or 0)
  end
  return capacity
end
M.getMaterialDeliveryCapacity = getMaterialDeliveryCapacity

local function formatTaskAmount(value, units)
  local amount = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
  return string.format("%s %s", tostring(amount), tostring(units or "L"))
end

local function clearTaskGuidance(contractId)
  if contractId then
    if taskGuidanceVisible[contractId] and guihooks then
      guihooks.trigger("DiscardTasklistItem", materialTaskId(contractId))
    end
    taskGuidanceVisible[contractId] = nil
    lastTaskGuidanceSignatures[contractId] = nil
    return
  end
  if guihooks then
    for activeId in pairs(taskGuidanceVisible) do
      guihooks.trigger("DiscardTasklistItem", materialTaskId(activeId))
    end
    guihooks.trigger("DiscardTasklistItem", legacyMaterialTaskId)
  end
  taskGuidanceVisible = {}
  lastTaskGuidanceSignatures = {}
end

local function refreshTaskGuidance(force)
  local seen = {}
  local shown = false
  for _, active in ipairs(getActiveContracts()) do
    if active.status == "active" then
      seen[active.id] = true
      shown = true

  local units = active.units or "L"
  local hasCargoInTransit = (active.inTransitAmount or 0) > 0
  local label
  if hasCargoInTransit then
    label = string.format("Deliver %s to %s", _tr(active.materialName), _tr(active.destinationName))
  else
    label = string.format("Go to %s loading point", _tr(active.sourceName))
  end
  local subtext = string.format(
    "%s delivered · %s in transit · %s remaining",
    formatTaskAmount(active.deliveredAmount, units),
    formatTaskAmount(active.inTransitAmount, units),
    formatTaskAmount(active.remainingAmount, units)
  )
  local signature = table.concat({label, subtext}, "|")
  if force or signature ~= lastTaskGuidanceSignatures[active.id] then
    guihooks.trigger("SetTasklistTask", {
      id = materialTaskId(active.id),
      label = label,
      subtext = subtext,
      active = true,
      type = "message",
    })
    lastTaskGuidanceSignatures[active.id] = signature
  end
      taskGuidanceVisible[active.id] = true
    end
  end
  local stale = {}
  for contractId in pairs(taskGuidanceVisible) do
    if not seen[contractId] then stale[#stale + 1] = contractId end
  end
  for _, contractId in ipairs(stale) do clearTaskGuidance(contractId) end
  return shown
end
M.refreshTaskGuidance = refreshTaskGuidance
M.clearTaskGuidance = clearTaskGuidance

local function canAcceptAtSource(offer)
  if not dCargoScreen or not dCargoScreen.isCargoScreenOpen or not dCargoScreen.isCargoScreenOpen() then return false end
  local location = dCargoScreen.getCargoScreenLocation and dCargoScreen.getCargoScreenLocation()
  return location and location.facId == offer.sourceFacId
end

local function acceptContract(offerId)
  local offer, facId, index = findOffer(offerId)
  if not offer or (offer.offerExpiresAt or 0) <= now() then return false end
  if not canAcceptAtSource(offer) then
    ui_message("Material contracts can only be accepted at their pickup facility.", 5, "warning")
    return false
  end

  local _, sourceStorage = getStorage(offer.sourceFacId, offer.materialType)
  local _, destinationStorage = getStorage(offer.destinationFacId, offer.materialType)
  if not sourceStorage or not sourceStorage.isProvider or not destinationStorage or not destinationStorage.isReceiver then
    table.remove(state.offersByFacility[facId], index)
    state.nextRefillByFacility[facId] = math.min(state.nextRefillByFacility[facId] or math.huge, now() + rules().refillInterval)
    ui_message("That material contract is no longer available.", 5, "warning")
    notifyChanged()
    return false
  end

  table.remove(state.offersByFacility[facId], index)
  local active = deepcopy(offer)
  active.status = "active"
  active.acceptedAt = now()
  active.deliveredAmount = 0
  active.paidRewards = {}
  active.usesVirtualStorage = true
  state.activeContracts[active.id] = active
  state.nextRefillByFacility[facId] = math.min(state.nextRefillByFacility[facId] or math.huge, now() + rules().refillInterval)
  ui_message(string.format("Contract accepted. Load %s at the %s loading point, then deliver it to %s.", _tr(offer.materialName), _tr(offer.sourceName), _tr(offer.destinationName)), 8, "info")
  refreshTaskGuidance(true)
  notifyChanged()
  return true
end
M.acceptContract = acceptContract

local function proportionalRewards(contractId, amount)
  local active = state.activeContracts[contractId]
  if not active then return {money = 0} end
  local ratio = math.max(0, tonumber(amount) or 0) / math.max(1, active.totalAmount)
  local result = {}
  for key, total in pairs(active.quotedRewards or {}) do result[key] = roundReward(total * ratio) end
  return result
end
M.getProportionalRewards = proportionalRewards

local function cumulativeRewardDelta(totalReward, totalAmount, beforeAmount, afterAmount)
  local divisor = math.max(1, tonumber(totalAmount) or 0)
  local before = clamp(tonumber(beforeAmount) or 0, 0, divisor)
  local after = clamp(tonumber(afterAmount) or 0, before, divisor)
  return roundReward((tonumber(totalReward) or 0) * after / divisor)
    - roundReward((tonumber(totalReward) or 0) * before / divisor)
end
M.calculateCumulativeRewardDelta = cumulativeRewardDelta

local function creditDelivery(contractId, amount)
  local active = state.activeContracts[contractId]
  if not active or active.status == "completed" then return nil end
  local before = active.deliveredAmount or 0
  local delivered = math.min(math.max(0, tonumber(amount) or 0), active.totalAmount - before)
  local after = before + delivered
  local rewards = {}
  active.paidRewards = active.paidRewards or {}
  for key, total in pairs(active.quotedRewards or {}) do
    local cumulative = roundReward(total * after / math.max(1, active.totalAmount))
    rewards[key] = cumulativeRewardDelta(total, active.totalAmount, before, after)
    active.paidRewards[key] = cumulative
  end
  active.deliveredAmount = after
  if after >= active.totalAmount - 0.0001 then active.status = "completed" end
  refreshTaskGuidance(true)
  return rewards
end
M.creditDelivery = creditDelivery

local function creditMaterialDelivery(materialType, location, amount)
  local remaining = math.max(0, tonumber(amount) or 0)
  local rewards = {money = 0}
  local credited = 0
  local allocations = {}

  for _, contract in ipairs(getContractsAcceptingMaterial(materialType, location)) do
    if remaining <= 0 then break end
    local allocationAmount = math.min(remaining, math.max(0, tonumber(contract.remainingAmount) or 0))
    if allocationAmount > 0 then
      local allocationRewards = creditDelivery(contract.id, allocationAmount) or {money = 0}
      for key, value in pairs(allocationRewards) do
        rewards[key] = (rewards[key] or 0) + value
      end
      allocations[#allocations + 1] = {
        contractId = contract.id,
        amount = allocationAmount,
        rewards = allocationRewards,
      }
      credited = credited + allocationAmount
      remaining = remaining - allocationAmount
    end
  end

  return rewards, credited, allocations
end
M.creditMaterialDelivery = creditMaterialDelivery

local function finalizeCompletedContracts()
  local completed = {}
  for _, active in ipairs(sortedActiveContracts()) do
    if active.status == "completed" then completed[#completed + 1] = active end
  end
  if #completed == 0 then return false end
  for _, active in ipairs(completed) do
    ui_message(string.format("Material contract complete: %s", _tr(active.materialName)), 6, "success")
    state.activeContracts[active.id] = nil
    clearTaskGuidance(active.id)
    local sourceFacId = active.sourceFacId
    state.nextRefillByFacility[sourceFacId] = math.min(state.nextRefillByFacility[sourceFacId] or math.huge, now() + rules().refillInterval)
  end
  notifyChanged()
  return true
end
M.finalizeCompletedContracts = finalizeCompletedContracts
M.finalizeCompletedContract = finalizeCompletedContracts

local function removeContractCargo(contractId)
  if not dParcelManager then return end
  local cargoItems = dParcelManager.getAllCargoCustomFilter(function(cargo)
    return cargo.data and cargo.data.materialContractId == contractId and cargo.location and cargo.location.type ~= "deleted"
  end) or {}
  for _, cargo in ipairs(cargoItems) do
    if cargo._transientMove and dParcelManager.clearTransientMoveForCargo then
      dParcelManager.clearTransientMoveForCargo(cargo.id)
    end
    dParcelManager.changeCargoLocation(cargo.id, {type = "deleted"})
  end
end

local function abandonContract(contractId)
  local active = state.activeContracts[contractId]
  if not active then return false end
  local remainingValue = math.max(0, (active.quotedRewards.money or 0) - ((active.paidRewards and active.paidRewards.money) or 0))
  local fine = roundReward(remainingValue * rules().abandonPenaltyFactor)
  removeContractCargo(active.id)
  if fine > 0 then
    career_modules_playerAttributes.addAttributes({money = -fine}, {
      tags = {"gameplay", "delivery", "fine"},
      label = "Material Contract Abandonment"
    })
  end
  local sourceFacId = active.sourceFacId
  state.activeContracts[active.id] = nil
  clearTaskGuidance(active.id)
  state.nextRefillByFacility[sourceFacId] = math.min(state.nextRefillByFacility[sourceFacId] or math.huge, now() + rules().refillInterval)
  ui_message(string.format("Material contract abandoned. Penalty: $%d", fine), 6, "warning")
  notifyChanged()
  if dGeneral and dGeneral.checkExitDeliveryMode then dGeneral.checkExitDeliveryMode() end
  return true
end
M.abandonContract = abandonContract

local function getUiState()
  return {
    offers = getAllOffers(),
    activeContracts = getActiveContracts(),
  }
end
M.getUiState = getUiState

local function onUpdate(dtReal, dtSim)
  if not initialized then return end
  updateAccumulator = updateAccumulator + (dtSim or 0)
  if updateAccumulator < 1 then return end
  updateAccumulator = updateAccumulator - 1
  local changed = false
  local currentTime = now()
  for facId in pairs(state.offersByFacility) do
    changed = expireOffersForFacility(facId) or changed
    local offers = state.offersByFacility[facId]
    if #offers < rules().maxOffersPerFacility and currentTime >= (state.nextRefillByFacility[facId] or 0) then
      if generateOfferForFacility(facId) then changed = true end
      state.nextRefillByFacility[facId] = currentTime + rules().refillInterval
    end
  end
  if changed then notifyChanged() end
  refreshTaskGuidance(false)
end
M.onUpdate = onUpdate

M.onCareerActivated = function()
  dGenerator = career_modules_delivery_generator
  dGeneral = career_modules_delivery_general
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  taskGuidanceVisible = {}
  lastTaskGuidanceSignatures = {}
end

M.isInitialized = function() return initialized end

M.runInvariantTests = function()
  local cfg = rules()
  local result = {errors = {}, offerCount = 0, facilityCounts = {}}
  local function check(condition, message)
    if not condition then result.errors[#result.errors + 1] = message end
  end

  check(math.abs(sharedCalc.getMaterialRouteFactor(1000) - 0.55) < 0.000001, "1 km route factor is not 0.55")
  check(math.abs(sharedCalc.getMaterialRouteFactor(4000) - 1.15) < 0.000001, "4 km route factor is not 1.15")
  check(getStandardLoad("water", dGenerator.getMaterialsTemplatesById("water")) == 17000, "fluid standard load mismatch")
  check(getStandardLoad("sand", dGenerator.getMaterialsTemplatesById("sand")) == 15600, "dry-bulk standard load mismatch")
  check(getStandardLoad("cement", dGenerator.getMaterialsTemplatesById("cement")) == 7800, "concrete standard load mismatch")
  check(getStandardLoad("cash", dGenerator.getMaterialsTemplatesById("cash")) == 500, "cash secure load mismatch")
  check(getStandardLoad("coin", dGenerator.getMaterialsTemplatesById("coin")) == 100, "coin secure load mismatch")
  check(getStandardLoad("gold", dGenerator.getMaterialsTemplatesById("gold")) == 250, "gold secure load mismatch")
  local deltaSum, before = 0, 0
  for _, after in ipairs({1, 4, 7, 10}) do
    deltaSum = deltaSum + cumulativeRewardDelta(101, 10, before, after)
    before = after
  end
  check(deltaSum == 101, "cumulative split rewards do not equal the quote")

  local activeIds = {}
  for _, contract in ipairs(getActiveContracts()) do
    check(not activeIds[contract.id], "duplicate active contract id " .. tostring(contract.id))
    activeIds[contract.id] = true
    check(contract.status == "active" or contract.status == "completed", "invalid active contract status")
    check(contract.usesVirtualStorage == true, "active contract still depends on physical storage capacity")
  end

  for facId, offers in pairs(state.offersByFacility or {}) do
    result.facilityCounts[facId] = #offers
    check(#offers <= cfg.maxOffersPerFacility, "offer cap exceeded at " .. tostring(facId))
    local pairsSeen = {}
    for _, offer in ipairs(offers) do
      result.offerCount = result.offerCount + 1
      check(offer.origin and offer.origin.type == "facilityParkingspot", "offer has no fixed source")
      check(offer.destination and offer.destination.type == "facilityParkingspot", "offer has no fixed receiver")
      check(math.abs((offer.offerExpiresAt - offer.createdAt) - cfg.offerDuration) < 0.001, "offer duration is not frozen at 15 delivery minutes")
      check(offer.totalAmount == offer.standardLoad * offer.loadCount, "offer quantity is outside its load band")
      check(offer.usesVirtualStorage == true, "offer still depends on physical storage capacity")
      local minLoads, maxLoads = getLoadRange(offer.materialType, dGenerator.getMaterialsTemplatesById(offer.materialType))
      check(offer.loadCount >= minLoads and offer.loadCount <= maxLoads, "offer load count is outside configured range")
      local pairKey = tostring(offer.materialType) .. "|" .. tostring(offer.destinationFacId)
      check(not pairsSeen[pairKey], "duplicate material/receiver pair at " .. tostring(facId))
      pairsSeen[pairKey] = true
    end
  end

  result.ok = #result.errors == 0
  result.serializable = pcall(jsonEncode, serialize())
  check(result.serializable, "contract state is not JSON serializable")
  result.ok = #result.errors == 0
  return result
end

return M
