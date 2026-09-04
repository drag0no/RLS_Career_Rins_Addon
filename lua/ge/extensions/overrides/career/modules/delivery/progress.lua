-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local xpConfig = require('gameplay/delivery/logisticsXPConfig')
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dParcelMods, dVehOfferManager, dVehicleTasks, dTutorial, dTasklist, dMaterialContracts
local step

local function bindDeliveryDeps()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTutorial = career_modules_delivery_tutorial
  dTasklist = career_modules_delivery_tasklist
  dMaterialContracts = career_modules_delivery_materialContractManager
  step = util_stepHandler
  return dGenerator ~= nil
end

M.onCareerActivated = function()
  bindDeliveryDeps()
end

local progress = {}

local progressTemplate = {

  cargoDeliveredByType = {
    parcel = 0,
    vehicle = 0,
    trailer = 0,
    fluid = 0,
    dryBulk = 0,
    cement = 0,
    cash = 0
  }
}

local function mergeDefaults(defaults, saved)
  if type(defaults) ~= "table" then
    if saved == nil then return deepcopy(defaults) end
    return saved
  end
  local result = {}
  for k, v in pairs(defaults) do
    result[k] = mergeDefaults(v, saved and saved[k])
  end
  if type(saved) == "table" then
    for k, v in pairs(saved) do
      if result[k] == nil then result[k] = v end
    end
  end
  return result
end

-- Keep delivery reward keys aligned with the unified logistics skill track.
local rewardKeyAliases = {
  ["logistics"] = "logistics-delivery",
  ["delivery"] = "logistics-delivery",
  ["vehicleDelivery"] = "logistics-delivery",
  ["materials"] = "logistics-delivery",
  ["logistics-vehicleDelivery"] = "logistics-delivery",
  ["logistics-materials"] = "logistics-delivery"
}

local function normalizeRewardKey(key)
  return rewardKeyAliases[key] or key
end

-- Multiplier metadata living on rewards tables must not be summed as payout attributes.
local rewardMetaKeys = {
  economyMultiplier = true,
  moneyMultiplier = true,
  economyBaseMoney = true,
}

local function normalizeRewardTable(rewardTable)
  local normalized = {}
  for key, amount in pairs(rewardTable or {}) do
    if not rewardMetaKeys[key] and type(amount) == "number" then
      local normalizedKey = normalizeRewardKey(key)
      normalized[normalizedKey] = (normalized[normalizedKey] or 0) + amount
    end
  end
  return normalized
end

local function getLogisticsMoneyBonusState()
  local level = career_branches.getBranchLevel("logistics-delivery")
  if type(level) ~= "number" then
    level = career_branches.getBranchLevel("logistics") or 0
  end

  local bonus = 0
  local effectiveLevel = math.max(1, math.min(50, math.floor(tonumber(level) or 1)))
  for unlockedLevel = 2, math.min(49, effectiveLevel) do
    if ((unlockedLevel - 2) % 2) + 1 == 1 then bonus = bonus + 0.08 end
  end
  if effectiveLevel >= 50 then bonus = bonus + 0.08 end
  return math.min(2, bonus), level
end

local function applyLogisticsMoneyBonusToEntry(entry, multiplier)
  if type(entry) ~= "table" or multiplier <= 0 then
    return 0
  end

  entry.adjustedRewards = normalizeRewardTable(entry.adjustedRewards)
  local baseMoney = entry.adjustedRewards.money or 0
  if baseMoney <= 0 then
    return 0
  end

  local roundingMode = xpConfig.getConfig().rounding.moneyFinal
  local bonusAmount = xpConfig.applyRounding(baseMoney * multiplier, roundingMode)
  if bonusAmount <= 0 then
    return 0
  end

  entry.adjustedRewards.money = baseMoney + bonusAmount
  entry.breakdown = entry.breakdown or {}
  table.insert(entry.breakdown, {
    label = string.format("Logistics Level Bonus (+%g%%)", multiplier * 100),
    rewards = {money = bonusAmount},
    simpleBreakdownType = "branch"
  })

  return bonusAmount
end

local function getBranchForAttributeKey(attributeKey)
  local function isValidBranch(candidate)
    return candidate and not candidate.missing and type(candidate.levels) == "table" and next(candidate.levels)
  end
  local function isCareerSkillsBranch(candidate)
    if type(candidate) ~= "table" then return false end
    if candidate.parentId == "careerSkills" then return true end
    if candidate.domainId == "careerSkills" then return true end
    if candidate.rootId == "careerSkills" then return true end
    if type(candidate.path) == "string" and candidate.path:find("careerSkills", 1, true) then return true end
    return false
  end

  local candidates = {}
  local byId = career_branches.getBranchById(attributeKey)
  if isValidBranch(byId) then
    table.insert(candidates, byId)
  end

  if career_branches.getBranchByPath then
    local byPath = career_branches.getBranchByPath(attributeKey)
    if isValidBranch(byPath) then
      table.insert(candidates, byPath)
    end
  end

  for _, candidate in ipairs(career_branches.getSortedBranches() or {}) do
    if candidate.attributeKey == attributeKey and isValidBranch(candidate) then
      table.insert(candidates, candidate)
    end
  end

  local bestBranch, bestScore = nil, -math.huge
  for _, candidate in ipairs(candidates) do
    local levelCount = #(candidate.levels or {})
    local score = levelCount
    if isCareerSkillsBranch(candidate) then score = score + 10000 end
    if candidate.parentId == "careerSkills" then score = score + 1000 end
    if attributeKey == "logistics-delivery" and candidate.id == "logistics" then score = score + 100 end
    if score > bestScore then
      bestBranch, bestScore = candidate, score
    end
  end

  return bestBranch
end

local function sanitizeBranchLevels(levels)
  if type(levels) ~= "table" then return {} end
  local result = {}
  local lastRequiredValue = 0
  for i, levelInfo in ipairs(levels) do
    local entry = type(levelInfo) == "table" and deepcopy(levelInfo) or {}
    if type(entry.requiredValue) ~= "number" then
      entry.requiredValue = lastRequiredValue
    end
    lastRequiredValue = entry.requiredValue
    entry.levelLabel = entry.levelLabel or ("Level " .. i)
    result[#result + 1] = entry
  end
  return result
end

local function calcBranchLevelSafe(value, branchRef)
  if type(branchRef) ~= "string" or branchRef == "" then return nil end
  local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, branchRef)
  if type(level) ~= "number" then return nil end
  return level, min, max
end

local function getAnimationDataForBranch(attributeKey, branch, branchLevels)
  local currentValue = career_modules_playerAttributes.getAttributeValue(attributeKey)
  local levelByKey, minByKey, maxByKey = calcBranchLevelSafe(currentValue, attributeKey)
  local levelById, minById, maxById = calcBranchLevelSafe(currentValue, branch.id)

  local level = levelByKey or levelById or 0
  local min = minByKey or minById or 0
  local max = maxByKey or maxById or 0
  if levelByKey and levelById then
    level = math.max(levelByKey, levelById)
    if level == levelByKey then
      min = minByKey or min
      max = maxByKey or max
    else
      min = minById or min
      max = maxById or max
    end
  end

  local levelLabel = career_branches.getLevelLabel(attributeKey, level)
  if type(levelLabel) ~= "string" or levelLabel == "" then
    levelLabel = career_branches.getLevelLabel(branch.id, level)
  end
  if type(levelLabel) ~= "string" or levelLabel == "" then
    levelLabel = "Level " .. tostring(level)
  end

  return {
    id = attributeKey,
    name = translateLanguage(branch.name, branch.name),
    level = level,
    levelLabel = levelLabel,
    value = currentValue,
    min = min,
    max = max,
    cover = branch.progressCover,
    glyphIcon = branch.icon,
    color = branch.color,
    accentColor = branch.accentColor,
    isMaxLevel = level >= #branchLevels,
    unlocked = branch.unlocked,
  }
end

-- Hide legacy/branch logistics rows in the delivery reward popup.
local hiddenDeliveryPopupAttributes = {
  logistics = true,
  delivery = true,
  vehicleDelivery = true,
  materials = true,
  ["logistics-vehicleDelivery"] = true,
  ["logistics-materials"] = true,
}

-- Prevent level-up popup animations for deprecated delivery keys.
local suppressedDeliveryLevelPopupAttributes = {
  logistics = true,
  delivery = true,
  vehicleDelivery = true,
  materials = true,
  ["logistics-vehicleDelivery"] = true,
  ["logistics-materials"] = true,
}

local function stripHiddenPopupRewardKeys(rewardTable)
  if type(rewardTable) ~= "table" then return rewardTable end
  for key, _ in pairs(hiddenDeliveryPopupAttributes) do
    rewardTable[key] = nil
  end
  return rewardTable
end

local function sanitizePopupBreakdown(breakdown)
  if type(breakdown) ~= "table" then return end
  for _, bd in ipairs(breakdown) do
    if type(bd) == "table" and type(bd.rewards) == "table" then
      stripHiddenPopupRewardKeys(bd.rewards)
    end
  end
end

local function sanitizePopupRewardContainer(entry)
  if type(entry) ~= "table" then return end
  if type(entry.rewards) == "table" then stripHiddenPopupRewardKeys(entry.rewards) end
  if type(entry.originalRewards) == "table" then stripHiddenPopupRewardKeys(entry.originalRewards) end
  if type(entry.adjustedRewards) == "table" then stripHiddenPopupRewardKeys(entry.adjustedRewards) end
  sanitizePopupBreakdown(entry.breakdown)
end

M.setProgress = function(data)
  progress = mergeDefaults(progressTemplate, data or {})
end

M.getProgress = function()
  return progress
end

M.onCargoDelivered = function(cargoItems)

  local affectedFacilities = {}

  for _, cargo in ipairs(cargoItems or {}) do
    if cargo.materialType == nil then
      progress.cargoDeliveredByType.parcel = progress.cargoDeliveredByType.parcel + 1
    else
      local material = dGenerator.getMaterialsTemplatesById(cargo.materialType)
      progress.cargoDeliveredByType[material.type] = (progress.cargoDeliveredByType[material.type] or 0) + cargo.slots
    end

    local cargoOrigFacility = dGenerator.getFacilityById(cargo.origin.facId)
    cargoOrigFacility.progress.deliveredFromHere.countByType.parcel = cargoOrigFacility.progress.deliveredFromHere.countByType.parcel + 1
    cargoOrigFacility.progress.deliveredFromHere.moneySum = cargoOrigFacility.progress.deliveredFromHere.moneySum + (cargo.rewards.money or 0)

    local cargoDestFacility = dGenerator.getFacilityById(cargo.location.facId)
    cargoDestFacility.progress.deliveredToHere.countByType.parcel = cargoDestFacility.progress.deliveredToHere.countByType.parcel + 1
    cargoDestFacility.progress.deliveredToHere.moneySum = cargoDestFacility.progress.deliveredToHere.moneySum + (cargo.rewards.money or 0)

    dParcelMods.trackModifierStats(cargo)

    affectedFacilities[cargo.origin.facId] = true
    affectedFacilities[cargo.location.facId] = true
  end

  extensions.hook("onDeliveryFacilityProgressStatsChanged", affectedFacilities)
end


M.onVehicleTasksFinished = function(offers)
  local affectedFacilities = {}
  for _, o in ipairs(offers or {}) do
    local offer = o.offer
    progress.cargoDeliveredByType[offer.data.type] = progress.cargoDeliveredByType[offer.data.type] + 1

    local vehOrigFacility = dGenerator.getFacilityById(offer.origin.facId)
    vehOrigFacility.progress.deliveredFromHere.countByType[offer.data.type] = vehOrigFacility.progress.deliveredFromHere.countByType[offer.data.type] + 1
    vehOrigFacility.progress.deliveredFromHere.moneySum = vehOrigFacility.progress.deliveredFromHere.moneySum + (offer.rewards.money or 0)

    local vehDestFacility = dGenerator.getFacilityById(offer.dropOffFacId)
    vehDestFacility.progress.deliveredToHere.countByType[offer.data.type] = vehDestFacility.progress.deliveredToHere.countByType[offer.data.type] + 1
    vehDestFacility.progress.deliveredToHere.moneySum = vehDestFacility.progress.deliveredToHere.moneySum + (offer.rewards.money or 0)

    affectedFacilities[offer.origin.facId] = true
    affectedFacilities[offer.dropOffFacId] = true
  end
  extensions.hook("onDeliveryFacilityProgressStatsChanged", affectedFacilities)
end

local unlockStatus = nil
M.aggregateBefore = function()
  unlockStatus = {
    skillLevels = {}
  }
  for skill, _ in pairs(career_branches.getBranches()) do
    unlockStatus.skillLevels[skill] = career_branches.getBranchLevel(skill)
  end
end

M.aggregateAfter = function()
  local results = {}
  --[[
  TODO: reimplement
  for skill, _ in pairs(skillUnlockDescriptions) do
    for lvl = unlockStatus.skillLevels[skill], career_branches.getBranchLevel(skill) do
      for _, unlock in ipairs(skillUnlockDescriptions[skill][lvl] or {}) do
        table.insert(results, unlock.unlocks)
      end
    end
  end
  ]]
  unlockStatus = nil
  return results
end

local dropOffDataStatus = nil
local confirmedDropOffData = nil
M.requestDropOffData = function(facId, psPath)
  if dropOffDataStatus ~= nil then
    if confirmedDropOffData ~= nil then
      log("W","","Already unloading cargo...")
      return
    end
    log("W","","Clearing stale drop-off data before opening cargo drop-off.")
    dropOffDataStatus = nil
  end
  dropOffDataStatus = {}
  dropOffDataStatus.affectedOfferIds = {}
  dropOffDataStatus.parcelData = {}
  dropOffDataStatus.vehicleData = {}
  dropOffDataStatus.trailerData = {}
  dropOffDataStatus.playerVehicleData = {}
  dropOffDataStatus.location = {type="facilityParkingspot", facId=facId, psPath=psPath}
  local rewardKeys = {}
  local playerVehiclesById = {}
  dGeneral.getNearbyVehicleCargoContainers(function(playerCargoContainers)
    local playerDestinationParkingSpots = {}
    local playerVehIds = {}
    for _, con in ipairs(playerCargoContainers) do
      playerVehIds[con.vehId] = true
      for _, cargo in ipairs(con.rawCargo) do
        local validCargo = false
        local contractCargo = cargo.data and cargo.data.materialContractId and cargo.materialType
        if contractCargo and dMaterialContracts then
          validCargo = dMaterialContracts.getMaterialDeliveryCapacity(cargo.materialType, dropOffDataStatus.location) > 0
        elseif not cargo.destination then
          validCargo = false
        elseif cargo.destination.type == "facilityParkingspot" then
          validCargo = dParcelManager.sameLocation(cargo.destination, dropOffDataStatus.location)
        elseif cargo.destination.type == "multi" then
          for _, dest in ipairs(cargo.destination.destinations) do
            validCargo = validCargo or dParcelManager.sameLocation(dest, dropOffDataStatus.location)
          end
        end

        if validCargo then
          if not playerVehiclesById[con.vehId] then
            playerVehiclesById[con.vehId] = { containers = {}, niceName = dGeneral.getVehicleName(con.vehId), vehId = con.vehId, containersById = {}}
          end
          if not playerVehiclesById[con.vehId].containersById[con.containerId] then
            playerVehiclesById[con.vehId].containersById[con.containerId] = {
              vehId = con.vehId,
              name = con.name,
              containerId = con.containerId,
              cargo = {},
              totalCargoSlots = con.totalCargoSlots,
              usedCargoSlots = con.usedCargoSlots,
              freeCargoSlots = con.freeCargoSlots,
            }
          end
          local displayCargo = cargo
          if contractCargo and not dParcelManager.sameLocation(cargo.destination, dropOffDataStatus.location) then
            displayCargo = deepcopy(cargo)
            displayCargo.destination = deepcopy(dropOffDataStatus.location)
          end
          table.insert(playerVehiclesById[con.vehId].containersById[con.containerId].cargo, displayCargo)
        end
      end
    end

    dropOffDataStatus.playerVehicleData = {}
    for vehId, vehicleInfo in pairs(playerVehiclesById) do
      for _, id in ipairs(tableKeysSorted(vehicleInfo.containersById)) do
        vehicleInfo.containersById[id].cargo = dParcelManager.addParcelRewardsSummary(deepcopy(vehicleInfo.containersById[id].cargo))
        table.insert(vehicleInfo.containers, vehicleInfo.containersById[id])
      end
      vehicleInfo.containersById = nil
      table.insert(dropOffDataStatus.playerVehicleData, vehicleInfo)
    end
    table.sort(dropOffDataStatus.playerVehicleData, function(a,b) return a.vehId < b.vehId end)
    dropOffDataStatus.rewardKeyIcons = rewardKeys
    dropOffDataStatus.vehicleData = dVehicleTasks.getVehicleDataWithRewardsSummary(psPath)
    local gatherSequence = dVehicleTasks.makeGatherVehicleDataSteps(dropOffDataStatus.vehicleData)
    if #gatherSequence > 0 then
      step.startStepSequence(gatherSequence, function()
        M.openDropOffScreenGatheringComplete()
      end)
    else
      M.openDropOffScreenGatheringComplete()
    end
  end)
end

M.unloadMaterialsManualStart = function(cargoId, destination)
  print("No longer used! unloadMaterialsManualStart")
end


local showSystemPopup = {}
M.openDropOffScreenGatheringComplete = function()
  -- patch in xp icons info
  local branchInfo = {}

  -- already calc if we need it
  local confirmedCargoIds = {}
  local confirmedOfferIds = {}

  --sort into automatic and non-automatic
  local automaticDropOffItems = {}
  local manualDropOffItems = {}
  for _, vehicleInfo in pairs(dropOffDataStatus.playerVehicleData or {}) do
    for _, con in pairs(vehicleInfo.containers) do
      for _, cargo in pairs(con.cargo) do
        cargo.vehicleName = vehicleInfo.name
        cargo.containerName = con.name
        if cargo.automaticDropOff then
          table.insert(automaticDropOffItems, cargo)
          for _, id in ipairs(cargo.ids) do
            table.insert(confirmedCargoIds, {id=id})
          end
        else
          table.insert(manualDropOffItems, cargo)
        end
        cargo.adjustedRewards = normalizeRewardTable(cargo.adjustedRewards)
        -- add in rewards keys..?
        for key, amount in pairs(cargo.adjustedRewards) do
          branchInfo[key] = true
        end
      end
    end
  end

  for _, vehData in ipairs(dropOffDataStatus.vehicleData or {}) do
    if vehData.finished then
      table.insert(automaticDropOffItems, vehData)
      table.insert(confirmedOfferIds, vehData.id)
      vehData.adjustedRewards = normalizeRewardTable(vehData.adjustedRewards)
      for key, amount in pairs(vehData.adjustedRewards) do
        branchInfo[key] = true
      end
    end
  end

  -- still waiting for vehicles to be finished, but show UI if there's cargo
  local hasPendingVehicles = false
  for _, data in ipairs(dropOffDataStatus.vehicleData or {}) do
    if not data.finished then
      hasPendingVehicles = true
      break
    end
  end

  -- if we have cargo to show, display UI even if vehicles are still gathering
  local hasCargoToShow = #manualDropOffItems > 0 or #automaticDropOffItems > 0
  if hasPendingVehicles and not hasCargoToShow then
    return
  end

  dropOffDataStatus.automaticDropOffItems = automaticDropOffItems
  dropOffDataStatus.manualDropOffItems = manualDropOffItems

  -- check how much i can unload for each material
  local unloadingMaterialInfoByKey = {}
  local fac = dGenerator.getFacilityById(dropOffDataStatus.location.facId)
  for _, item in ipairs(manualDropOffItems) do
    local materialType = item.materialType
    local storage = materialType and fac and fac.materialStorages and fac.materialStorages[materialType]
    if materialType and storage then
      local isContract = item.materialContractId ~= nil or (item.data and item.data.materialContractId ~= nil)
      -- addParcelRewardsSummary clusters cargo before this point and does not
      -- consistently retain the data table. Resolve the original IDs so the
      -- contract/ordinary capacity paths can never be mixed up.
      if not isContract then
        for _, cargoId in ipairs(item.ids or {}) do
          local rawCargo = dParcelManager.getCargoById(cargoId)
          if rawCargo and rawCargo.data and rawCargo.data.materialContractId then
            isContract = true
            break
          end
        end
      end
      local storageKey = string.format("%s|%s", materialType, isContract and "contract" or "storage")
      unloadingMaterialInfoByKey[storageKey] = unloadingMaterialInfoByKey[storageKey] or {
        storage = storage,
        materialType = materialType,
        virtualCapacity = isContract,
        amountToUnload = 0,
        items = {},
      }
      unloadingMaterialInfoByKey[storageKey].amountToUnload = unloadingMaterialInfoByKey[storageKey].amountToUnload + item.slots
      table.insert(unloadingMaterialInfoByKey[storageKey].items, item)
    else
      log("W", "", string.format("Skipping manual drop-off item without receiver storage: %s", item.name or item.id or "unknown cargo"))
    end
  end


  dropOffDataStatus.customAmountPerMaterialType = {}
  for _, storageKey in pairs(tableKeysSorted(unloadingMaterialInfoByKey)) do
    local info = unloadingMaterialInfoByKey[storageKey]
    info.material = dGenerator.getMaterialsTemplatesById(info.materialType)
    if info.virtualCapacity then
      -- A contract receiver is a project sink, not the facility's normal
      -- inventory tank. Cap the selector at the unfilled amount across every
      -- active contract for this material at this marker.
      local acceptingCapacity = dMaterialContracts
        and dMaterialContracts.getMaterialDeliveryCapacity(info.materialType, dropOffDataStatus.location) or 0
      info.storage = {
        capacity = math.min(info.amountToUnload, acceptingCapacity),
        storedVolume = 0,
        target = 0,
        materialType = info.materialType,
      }
    end

    table.insert(dropOffDataStatus.customAmountPerMaterialType, info)
  end


  if next(dropOffDataStatus.customAmountPerMaterialType) then

    for key, _ in pairs(branchInfo) do
      branchInfo[key] = {
        icon = career_branches.getBranchIcon(key),
        order = career_branches.getOrder(key)
      }
      if key:endswith("Reputation") then
        branchInfo[key].order, branchInfo[key].icon = 7000, "peopleOutline" --freeroam_organizations.getOrganizationIdOrderAndIcon()
      end
    end
    --dump(dropOffDataStatus)
    dropOffDataStatus.branchInfo = branchInfo
    guihooks.trigger("SetDeliveryDropOffCargoSelection", dropOffDataStatus)
    gameplay_markerInteraction.closeViewDetailPrompt(true)
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
    gameplay_rawPois.clear()
  else
    local confirmedDropOffs = {
      confirmedCargoIds = confirmedCargoIds,
      confirmedOfferIds = confirmedOfferIds,
    }
    M.confirmDropOffData(confirmedDropOffs, dropOffDataStatus.location.facId, dropOffDataStatus.location.psPath)
  end
end

M.confirmDropOffData = function(confirmedDropOffs, facId, psPath)
  if confirmedDropOffData ~= nil then log("W","","Already dropoffing cargo...") return end
  local location = {type="facilityParkingspot", facId=facId, psPath=psPath}
  confirmedDropOffData = {}
  confirmedDropOffData.parcelIdElems = confirmedDropOffs.confirmedCargoIds or {}
  confirmedDropOffData.offerIds = confirmedDropOffs.confirmedOfferIds or {}
  confirmedDropOffData.cargo = {}
  --dump(confirmedDropOffs)
  if dGeneral.rememberCurrentCargoWeightVehicles then
    dGeneral.rememberCurrentCargoWeightVehicles()
  end

  local function deliverCargo(cargo, takeAmount)
    local isContractCargo = cargo.data and cargo.data.materialContractId and dMaterialContracts
    if isContractCargo then
      local acceptingCapacity = dMaterialContracts.getMaterialDeliveryCapacity(cargo.materialType, location)
      takeAmount = math.min(tonumber(takeAmount) or cargo.slots, acceptingCapacity)
    end
    if takeAmount then
      takeAmount = tonumber(takeAmount) or 0
      if takeAmount <= 0 then
        return nil
      end
      if takeAmount < cargo.slots then
        local parts = dGenerator.splitOffPartsFromMaterialCargo(cargo, {takeAmount})
        cargo = parts[2]
      end
    end

    dParcelManager.changeCargoLocation(cargo.id, location)

    if isContractCargo then
      local credited
      local allocations
      cargo.rewards, credited, allocations = dMaterialContracts.creditMaterialDelivery(cargo.materialType, location, cargo.slots)
      cargo.rewards = cargo.rewards or {money = 0}
      cargo.data.fulfilledMaterialContracts = allocations
      if credited < cargo.slots - 0.0001 then
        log("W", "", string.format("Only credited %0.1fL of %0.1fL %s contract cargo", credited, cargo.slots, tostring(cargo.materialType)))
      end
    elseif cargo.materialType and not cargo.automaticDropOff then
      dGenerator.finalizeMaterialDistanceRewards(cargo, location)
    end

    cargo.originalRewards, cargo.breakdown, cargo.adjustedRewards = dParcelManager.getRewardsWithBreakdown(cargo)
    cargo.adjustedRewards = normalizeRewardTable(cargo.adjustedRewards)
    table.insert(confirmedDropOffData.cargo, cargo)
    return cargo
  end

  for _, elem in ipairs(confirmedDropOffData.parcelIdElems) do
    local ids = type(elem.ids) == "table" and elem.ids or nil
    if not ids or not ids[1] then
      ids = elem.id and {elem.id} or {}
    end
    local remaining = tonumber(elem.amount)
    for _, cargoId in ipairs(ids) do
      local cargo = dParcelManager.getCargoById(cargoId)
      if not cargo then
        log("W", "", string.format("Skipping missing cargo during drop-off confirmation: %s", tostring(cargoId)))
      elseif remaining ~= nil and remaining <= 0 then
        break
      else
        local takeAmount = remaining
        if remaining ~= nil then
          takeAmount = math.min(remaining, cargo.slots)
          remaining = remaining - takeAmount
        end
        deliverCargo(cargo, takeAmount)
      end
    end
    if remaining and remaining > 0.0001 then
      log("W", "", string.format("Drop-off amount %s could not be fully consumed from cargo ids %s", tostring(elem.amount), dumps(ids)))
    end
  end

  confirmedDropOffData.offers = dVehicleTasks.finishTasks(confirmedDropOffData.offerIds)
  confirmedDropOffData.weightUpdateComplete = false
  dGeneral.requestUpdateContainerWeights()
  confirmedDropOffData.onComplete = nop
  dGeneral.updateContainerWeights(function(data)
    data = data or {}
    confirmedDropOffData.weightUpdateComplete = true
    local maxDelay = 0
    for _, delay in pairs(data) do
      maxDelay = math.max(delay, maxDelay)
    end
    maxDelay = maxDelay
    if maxDelay >= 1 then
      confirmedDropOffData.maxDelayForWeightUpdate = maxDelay
      confirmedDropOffData.onComplete = function()
        local sequence = {
          step.makeStepWait(maxDelay+0.5),
          step.makeStepReturnTrueFunction(function()
            for vehId, delay in pairs(data) do
              local veh = scenetree.findObjectById(vehId)
              core_vehicleBridge.executeAction(veh, 'setFreeze', false)
            end
          return true
          end
          )
        }
        step.startStepSequence(sequence, callback)
      end
    else
      confirmedDropOffData.maxDelayForWeightUpdate = 0
      -- 1s delay, no freeze
      for vehId, delay in pairs(data) do
        local veh = scenetree.findObjectById(vehId)
        core_vehicleBridge.executeAction(veh, 'setFreeze', false)
      end
    end
    M.confirmDropOffCheckComplete()
  end)
  --M.confirmDropOffCheckComplete()
end

M.confirmDropOffCheckComplete = function()
  if not confirmedDropOffData then return end

    -- still waiting for vehicles to be finished
  for _, data in ipairs(confirmedDropOffData.offers or {}) do
    if not data.finished then return end
  end
  if not confirmedDropOffData.weightUpdateComplete then
    return
  end

  local rewards = {}
  local itemNames = {}
  local branchInfo = {}
  local rewardParcels = {}
  local levelMoneyBonusMultiplier = getLogisticsMoneyBonusState()



  -- add rewards for parcels, then for vehicles
  -- group cargo

   --current location also needs to be the same, but that is guaranteed by the caller of this function
  local cargoByGroupId = {}
  for _, c in ipairs(confirmedDropOffData.cargo) do
    local gId = string.format("%d-%d", c.groupId, c.loadedAtTimeStamp or -1)
    cargoByGroupId[gId] = cargoByGroupId[gId] or {}
    -- finalize the fields that require "costly" computation at this point
    table.insert(cargoByGroupId[gId], c)
    c.adjustedRewards = normalizeRewardTable(c.adjustedRewards)
    if not (c.data and c.data.materialContractId) then
      applyLogisticsMoneyBonusToEntry(c, levelMoneyBonusMultiplier)
    end
    table.insert(rewards, c.adjustedRewards)
    c.summaryId = gId
    table.insert(rewardParcels, c)
  end
    -- format each group individually
  for gId, group in pairs(cargoByGroupId) do
    table.insert(itemNames, string.format("%dx %s", #group, _tr(group[1].name)))
  end

  for _, formattedOffer in ipairs(confirmedDropOffData.offers) do
    table.insert(itemNames, string.format("%s %s",formattedOffer.offer.name, formattedOffer.offer.vehicle.name))
    formattedOffer.adjustedRewards = normalizeRewardTable(formattedOffer.adjustedRewards)
    applyLogisticsMoneyBonusToEntry(formattedOffer, levelMoneyBonusMultiplier)
    table.insert(rewards, formattedOffer.adjustedRewards)
  end


  -- calculate the simple and detailled breakdowns for UI


  local rewardSum = {}
  for _, reward in ipairs(rewards) do
    for key, amount in pairs(reward) do
      rewardSum[key] = (rewardSum[key] or 0) + amount
    end
  end
  rewardSum = normalizeRewardTable(rewardSum)
  for key, _ in pairs(rewardSum) do
    branchInfo[key] = true
  end
  --[[
  local aggregateChange = {}
  for key, _ in ipairs(branchInfo) do
    local branch = career_branches.getBranchById(key)
    if branch.id == "key" then
      local level, curLvlProgress, neededForNext, prevThreshold, nextThreshold = career_branches.calcBranchLevelFromValue(career_modules_playerAttributes.getAttributeValue(key), key)
      aggregateChange[key] = {
        isBranch = true,
        valueBefore = career_modules_playerAttributes.getAttributeValue(key),
        levelInfoBefore = {
          level = level,
          curLvlProgress = curLvlProgress,
          neededForNext = neededForNext,
          prevThreshold = prevThreshold,
          nextThreshold = nextThreshold
        }
      }
  end
  ]]
  local rewardTags = {"gameplay", "deliveryReward"}
  local typeSeen = {}
  for _, c in ipairs(confirmedDropOffData.cargo or {}) do
    local ecoKey
    if c.materialType then
      local mat = dGenerator.getMaterialsTemplatesById and dGenerator.getMaterialsTemplatesById(c.materialType)
      local matType = mat and mat.type
      if matType == "fluid" then ecoKey = "delivery_fluid"
      elseif matType == "dryBulk" then ecoKey = "delivery_dryBulk"
      elseif matType == "cement" then ecoKey = "delivery_cement"
      elseif matType == "cash" then ecoKey = "delivery_cash"
      else ecoKey = "delivery_trailer"
      end
    else
      ecoKey = "delivery_parcel"
    end
    if ecoKey and not typeSeen[ecoKey] then
      typeSeen[ecoKey] = true
      table.insert(rewardTags, ecoKey)
    end
  end
  if confirmedDropOffData.offers and #confirmedDropOffData.offers > 0 then
    if not typeSeen["delivery_vehicle"] then
      table.insert(rewardTags, "delivery_vehicle")
      typeSeen["delivery_vehicle"] = true
    end
  end

  -- Best stamped demand multiplier from this drop-off (baked at offer generation).
  local stampedDemandFactor, stampedDemandBonus = 1, 0
  local function considerStampedDemand(rewardTable)
    if type(rewardTable) ~= "table" then return end
    local m = tonumber(rewardTable.economyMultiplier) or 1
    local money = tonumber(rewardTable.money) or 0
    if m > stampedDemandFactor then stampedDemandFactor = m end
    if money > 0 and m > 1.001 then
      stampedDemandBonus = stampedDemandBonus + money * (m - 1) / m
    end
  end
  local function firstStampedReward(...)
    for i = 1, select("#", ...) do
      local rewardTable = select(i, ...)
      if type(rewardTable) == "table" and rewardTable.economyMultiplier ~= nil then
        return rewardTable
      end
    end
  end
  for _, c in ipairs(confirmedDropOffData.cargo or {}) do
    considerStampedDemand(firstStampedReward(c.rewards, c.originalRewards, c.adjustedRewards))
  end
  for _, offerData in ipairs(confirmedDropOffData.offers or {}) do
    local offer = offerData.offer or offerData
    considerStampedDemand(firstStampedReward(
      offer and offer.rewards,
      offerData.originalRewards,
      offerData.adjustedRewards,
      offerData.formatted and offerData.formatted.rewards
    ))
  end

  career_modules_playerAttributes.addAttributes(rewardSum, {
    label = {
      txt = "ui.career.attributeLog.deliveryRewardsFor",
      context = { items = table.concat(itemNames, ", ") },
    },
    tags = rewardTags,
    demandFactor = (stampedDemandFactor > 1.001) and stampedDemandFactor or nil,
  }, true)

  for key, _ in pairs(branchInfo) do

    if key:endswith("Reputation") then
      local orgId = key:sub(1, -11)
      local organization = freeroam_organizations.getOrganization(orgId)
      branchInfo[key] = {
        icon = "peopleOutline",
        order = 7000,
        animationData = {
          name = core_locales.contextTranslate("ui.career.organizations.reputationAnimationName", {organizationName = _tr(organization.name)}),
          max = organization.reputation.nextThreshold,
          min = organization.reputation.prevThreshold,
          value = organization.reputation.value
        },
        type = "reputation",
        branchLevels = organization.reputationLevels
      }
    else
      local branch = getBranchForAttributeKey(key)
      if branch and not branch.missing then
        local branchLevels = sanitizeBranchLevels(branch.levels)
        local animationData = getAnimationDataForBranch(key, branch, branchLevels)
        local hasValidLevels = #branchLevels > 0 and type(branchLevels[1].requiredValue) == "number"
        branchInfo[key] = {
          icon = career_branches.getBranchIcon(key) or branch.icon,
          order = career_branches.getOrder(key) or branch.order or 9999,
          animationData = animationData,
          branchLevels = branchLevels,
          showLevelUpPopup = hasValidLevels and not suppressedDeliveryLevelPopupAttributes[key],
          unlockPopupHeader = string.format("%s %s: Level %d", translateLanguage(branch.name, branch.name), branch.isSkill and "Skill" or "Branch", animationData.level or 0)
        }
        if type(branchInfo[key].animationData.levelLabel) == "table" then
          branchInfo[key].animationData.levelLabel = "Level " .. tostring(branchInfo[key].animationData.level or 0)
        end

        if branch.isBranch then branchInfo[key].animationData.name = "Branch: " .. translateLanguage(branchInfo[key].animationData.name, branchInfo[key].animationData.name) end
        if branch.isSkill then branchInfo[key].animationData.name = "Skill: " .. translateLanguage(branchInfo[key].animationData.name, branchInfo[key].animationData.name) end
      else
        branchInfo[key] = {
          icon = career_branches.getBranchIcon(key) or "beamXPLo",
          order = career_branches.getOrder(key) or 9999,
          animationData = {
            type = "number",
            name = key,
            value = career_modules_playerAttributes.getAttributeValue(key)
          },
          branchLevels = {},
          showLevelUpPopup = false,
        }
      end
    end

    if key == "money" then
      branchInfo[key].icon = "beamCurrency"
      branchInfo[key].animationData = {
        type = "number",
        name = "Money",
        value = career_modules_playerAttributes.getAttribute("money").value
      }
    end

    if key == "beamXP" then
      branchInfo[key].icon = "beamXPLo"
      branchInfo[key].animationData = {
        type = "number",
        name = "BeamXP",
        value = career_modules_playerAttributes.getAttribute("beamXP").value
      }
    end
  end
  local popupBranchInfo = deepcopy(branchInfo)
  for key, _ in pairs(hiddenDeliveryPopupAttributes) do
    popupBranchInfo[key] = nil
  end

  local popupRewardParcels = deepcopy(rewardParcels)
  for _, parcel in ipairs(popupRewardParcels) do
    sanitizePopupRewardContainer(parcel)
  end

  local popupRewardOffers = deepcopy(confirmedDropOffData.offers or {})
  for _, offerData in ipairs(popupRewardOffers) do
    sanitizePopupRewardContainer(offerData)
  end

  local rewardResult = {
    rewardParcels = popupRewardParcels,
    rewardOffers = popupRewardOffers,
    branchInfo = popupBranchInfo,
    unloadingDelay = confirmedDropOffData.maxDelayForWeightUpdate,
    demandInfo = nil,
  }

  local hotThreshold = (career_modules_activityHeat and career_modules_activityHeat.HOT_THRESHOLD) or 1.10
  if stampedDemandFactor >= hotThreshold and stampedDemandBonus >= 1 then
    rewardResult.demandInfo = {
      factor = stampedDemandFactor,
      pct = math.floor((stampedDemandFactor - 1) * 100 + 0.5),
      bonusMoney = math.floor(stampedDemandBonus + 0.5),
      label = "High demand",
    }
  end

  guihooks.trigger("SetDeliveryDropOffRewardResult", rewardResult)

  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_02')
  gameplay_markerInteraction.setForceReevaluateOpenPrompt(true)
  gameplay_rawPois.clear()

  M.onVehicleTasksFinished(confirmedDropOffData.offers)
  M.onCargoDelivered(confirmedDropOffData.cargo)
  if dMaterialContracts then dMaterialContracts.finalizeCompletedContracts() end
  for _, offer in ipairs(confirmedDropOffData.offers or {}) do
    if offer.offer and offer.offer.id then
      dTasklist.clearTasklistForOfferId(offer.offer.id)
    end
  end
  dTasklist.sendCargoToTasklist()
  confirmedDropOffData.onComplete()
  dGeneral.checkExitDeliveryMode()
  confirmedDropOffData = nil
  dropOffDataStatus = nil

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end


M.unloadCargoPopupClosed = function()
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_02')
  career_modules_tutorialPopups.introPopup("cargoDelivered")
  if next(showSystemPopup) then
    for _, key in ipairs(showSystemPopup) do
      career_modules_tutorialPopups.introPopup(key.."Unlocked")
    end
  end
  gameplay_markerInteraction.setForceReevaluateOpenPrompt()
end

M.dropOffPopupClosed = function(mode)
  if mode == "cargoSelection" and confirmedDropOffData == nil then
    dropOffDataStatus = nil
  end
end



M.isFacilityUnlocked = function(facId)
  if not bindDeliveryDeps() then return false end
  local fac = dGenerator.getFacilityById(facId)
  if not fac then
    return false
  end
  if not fac.unlockCondition then
    return true
  end
  if fac.unlockCondition.type == "minItemCount" then
    local val = fac.progress.itemsDeliveredToHere.count
    local tgt = fac.unlockCondition.target
    if val >= tgt then
      return true
    else
      return false, {
        disabledReasonHeader = "Facility not yet unlocked!",
        disabledReasonContent = string.format("Deliver %d Items here to be able to deliver from here.",tgt),
        progress = {
          {type="progressBar",minValue=0,maxValue=tgt,currValue=val, label=string.format("%d / %d Items delivered.", val, tgt)}
        }
      }
    end
  elseif fac.unlockCondition.type == "branchLevel" then
  end
  return true
end

M.isFacilityVisible = function(facId, isCargoDeliveryTutorialActive)
  if not bindDeliveryDeps() then return false end
  if isCargoDeliveryTutorialActive then
    if not dGenerator.getFacilityById(facId) or dGenerator.getFacilityById(facId).isTutorialForCargoDelivery then
      return false
    end
  end


  local fac = dGenerator.getFacilityById(facId)
  if not fac then
    return false
  end
  if not fac.visibleCondition then
    return true
  end
  if fac.visibleCondition.type == "minItemCount" then
    local val = fac.progress.itemsDeliveredToHere.count
    local tgt = fac.unlockCondition.target
    if val >= tgt then
      return true
    else
      return false
    end
  end
  return true
end


M.getFacilityCountForCargoCount = function(direction)
  local count = 0
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local c = 0
    for key, v in pairs(facility.progress[direction].countByType) do
      c = c + v
    end
    if c > 0 then count = count + 1 end
  end
  return count
end


M.getMoneyMultiplerForSkill = function(skill, tier)
  return career_branches.getLevelRewardMultiplier("logistics")
end


local function onBranchTierReached(skill, tier)
  if skill == "logistics-delivery" then return end
end

local soundObjectIds = {}
local soundNames = {
  money = 'event:>UI>Career>Progress_Money',
  progressBar = 'event:>UI>Career>Progress_XP'
}

local function activateSound(soundLabel, active)
  soundObjectIds["money"] = soundObjectIds["money"] or Engine.Audio.createSource('AudioGui', soundNames["money"])
  soundObjectIds["progressBar"] = soundObjectIds["progressBar"] or Engine.Audio.createSource('AudioGui', soundNames["progressBar"])
  if active then
    local sound = scenetree.findObjectById(soundObjectIds[soundLabel])
    if sound then
      sound:play(-1)
    end
  else
    for label, _ in pairs(soundNames) do
      local sound = scenetree.findObjectById(soundObjectIds[label])
      if sound then
        sound:stop(-1)
      end
    end
  end
end
M.activateSound = activateSound


M.onBranchTierReached = onBranchTierReached

return M
