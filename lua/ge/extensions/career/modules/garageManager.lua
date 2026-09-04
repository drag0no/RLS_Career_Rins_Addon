local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'freeroam_facilities', 'career_modules_propertyOwners', 'career_modules_difficultyMode' }

local purchasedGarages = {}
local discoveredGarages = {}
local garageAcquisitions = {}
-- Grants the player moved out of: sticky across loads until they reclaim (or buy).
local relinquishedGrants = {}
local garageToPurchase = nil
local saveFile = "purchasedGarages.json"

local garageSize = {}
local CLOSING_FEE_RATE = 0.03
local PROPERTY_TAX_RATE = 0.012
local requestGarageListing
local pendingGarageListingData = nil

local NEGOTIATION_COOLDOWN_SECONDS = 30 * 60
local negotiationCooldowns = {}
local frozenPrices = {}
local pendingNegotiatedPrices = {}

local function isHardcoreMode()
  return career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode and career_modules_difficultyMode.isHardcoreMode()
end

local function savePurchasedGarages(currentSavePath)
  if not currentSavePath then
    local slot, path = career_saveSystem.getCurrentProfile()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  local data = {
    garages    = purchasedGarages,
    discovered = discoveredGarages,
    acquisitions = garageAcquisitions,
    relinquishedGrants = relinquishedGrants,
  }
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, data, true)
end

local function saveNegotiationCooldowns(currentSavePath)
  if not currentSavePath then
    local slot, path = career_saveSystem.getCurrentProfile()
    currentSavePath = path
    if not currentSavePath then return end
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  
  local data = {
    cooldowns = negotiationCooldowns,
    frozenPrices = frozenPrices
  }
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/negotiationCooldowns.json", data, true)
end

local function loadNegotiationCooldowns()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/negotiationCooldowns.json"
  local data = jsonReadFile(filePath)
  if data then
    negotiationCooldowns = data.cooldowns or {}
    frozenPrices = data.frozenPrices or {}
    
    local currentTime = career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue("simTime") or 0
    for garageId, cooldownTime in pairs(negotiationCooldowns) do
      if currentTime - cooldownTime > NEGOTIATION_COOLDOWN_SECONDS then
        negotiationCooldowns[garageId] = nil
        if not frozenPrices[garageId] then
          frozenPrices[garageId] = nil
        end
      end
    end
  end
end

local function getCurrentSimTime()
  return os.time()
end

local function canNegotiateGarage(garageId)
  if not garageId then return false, 0 end
  
  local currentTime = getCurrentSimTime()
  local lastNegotiationTime = negotiationCooldowns[garageId]
  
  if not lastNegotiationTime then
    return true, 0
  end
  
  local timeSinceNegotiation = currentTime - lastNegotiationTime
  local cooldownRemaining = math.max(0, NEGOTIATION_COOLDOWN_SECONDS - timeSinceNegotiation)
  
  return cooldownRemaining == 0, cooldownRemaining
end

local function setNegotiationCooldown(garageId)
  if not garageId then return end
  negotiationCooldowns[garageId] = getCurrentSimTime()
end

local function freezeNegotiatedPrice(garageId, price)
  if not garageId or not price then return end
  frozenPrices[garageId] = {
    price = price,
    timestamp = getCurrentSimTime()
  }
end

local function getFrozenPrice(garageId)
  if not garageId then return nil end
  local frozen = frozenPrices[garageId]
  if not frozen then return nil end
  
  local currentTime = getCurrentSimTime()
  local timeSinceFreeze = currentTime - frozen.timestamp
  
  if timeSinceFreeze > NEGOTIATION_COOLDOWN_SECONDS then
    frozenPrices[garageId] = nil
    return nil
  end
  
  return frozen.price
end

local function getPendingNegotiatedPrice(garageId)
  if not garageId then return nil end
  local pending = pendingNegotiatedPrices[garageId]
  if not pending then return nil end

  local currentTime = getCurrentSimTime()
  local timeSinceOffer = currentTime - pending.timestamp
  if timeSinceOffer > NEGOTIATION_COOLDOWN_SECONDS then
    pendingNegotiatedPrices[garageId] = nil
    return nil
  end

  return pending.price
end

local function setPendingNegotiatedPrice(garageId, price)
  if not garageId or not price then return end
  pendingNegotiatedPrices[garageId] = {
    price = price,
    timestamp = getCurrentSimTime()
  }
end

local function clearPendingNegotiatedPrice(garageId)
  if garageId then
    pendingNegotiatedPrices[garageId] = nil
  end
end

local function clearFrozenPrice(garageId)
  if garageId then
    frozenPrices[garageId] = nil
  end
end

local function onSaveCurrentProfile(currentSavePath)
  log("D", "garageManager", "Saving garage data to: " .. currentSavePath .. "/career/rls_career/" .. saveFile)
  savePurchasedGarages(currentSavePath)
  saveNegotiationCooldowns(currentSavePath)
end

local function isPurchasedGarage(garageId)
  return purchasedGarages[garageId] or false
end

local function isNotPurchasableGarage(garageId, garage)
  if not garageId then return false end
  local getFacilityIfExists = freeroam_facilities.getFacilityIfExists
    or function(type, id) return freeroam_facilities.getFacility(type, id, true) end
  garage = garage or getFacilityIfExists("garage", garageId)
  return garage and garage.notPurchasable == true
end

local function normalizeAcquisition(acquisition)
  if type(acquisition) ~= "table" then
    return { type = "grant", amountPaid = 0 }
  end
  local amountPaid = math.max(0, math.floor(tonumber(acquisition.amountPaid) or 0))
  local acqType = acquisition.type
  if acqType ~= "purchase" and acqType ~= "finance" and acqType ~= "grant" then
    acqType = amountPaid > 0 and "purchase" or "grant"
  end
  if acqType ~= "grant" and amountPaid <= 0 then
    acqType = "grant"
  end
  return { type = acqType, amountPaid = amountPaid }
end

local function setGarageAcquisition(garageId, acquisition)
  if not garageId then return end
  garageAcquisitions[garageId] = normalizeAcquisition(acquisition)
end

local function clearGarageAcquisition(garageId)
  if garageId then
    garageAcquisitions[garageId] = nil
  end
end

local function getGarageAcquisition(garageId)
  if not garageId then return nil end
  local info = garageAcquisitions[garageId]
  if info then
    return normalizeAcquisition(info)
  end
  return nil
end

local function wasGaragePurchasedWithMoney(garageId)
  local info = getGarageAcquisition(garageId)
  return info ~= nil and (tonumber(info.amountPaid) or 0) > 0
end

local function isGrantedGarageOwnership(garageId)
  if not garageId or not purchasedGarages[garageId] then return false end
  return not wasGaragePurchasedWithMoney(garageId)
end

local function isRelinquishedGrant(garageId)
  return garageId and relinquishedGrants[garageId] == true
end

local function markRelinquishedGrant(garageId)
  if garageId then
    relinquishedGrants[garageId] = true
  end
end

local function clearRelinquishedGrant(garageId)
  if garageId then
    relinquishedGrants[garageId] = nil
  end
end

local function isAccessibleGarage(garageId)
  if isNotPurchasableGarage(garageId) then return false end
  if purchasedGarages[garageId] then return true end
  if career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garageId) then return true end
  return false
end

local function isDiscoveredGarage(garageId)
  return discoveredGarages[garageId] or false
end

local function isGarageForSale(garageId)
  if not garageId then return false end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPropertyListing then return false end
  return career_modules_realEstateNegotiation.getPropertyListing(garageId) ~= nil
end

local function isChallengeStartingGarage(garageId)
  if not garageId then return false end
  if not career_challengeModes or not career_challengeModes.isChallengeActive() then return false end

  local activeChallenge = career_challengeModes.getActiveChallenge()
  if not activeChallenge or not activeChallenge.startingGarages then return false end

  for _, startingGarageId in ipairs(activeChallenge.startingGarages) do
    if startingGarageId == garageId then
      return true
    end
  end

  return false
end

local function getManualStartingGaragePreference()
  if career_career and career_career.getStartingGaragePreference then
    return career_career.getStartingGaragePreference() or {mode = "default", garageId = nil}
  end
  return {mode = "default", garageId = nil}
end

local function isManualStartingGarage(garageId)
  if not garageId then return false end

  local preference = getManualStartingGaragePreference()
  if preference.mode ~= "default" or not preference.garageId or preference.garageId == "" then
    return false
  end

  return preference.garageId == garageId
end

local function getDefaultStartingGarageId(levelName)
  local facilities = freeroam_facilities.getFacilities(levelName or getCurrentLevelIdentifier())
  if not facilities or not facilities.garages then
    return nil
  end

  for _, garage in ipairs(facilities.garages) do
    if garage.starterGarage then
      return garage.id
    end
  end

  return nil
end

-- Free random starter pool: current map only, price in (0, 50000].
local MAX_RANDOM_STARTING_GARAGE_PRICE = 50000

local function isEligibleRandomStartingGarage(garage)
  if type(garage) ~= "table" or not garage.id then
    return false
  end
  if garage.notPurchasable == true then
    return false
  end
  local price = tonumber(garage.defaultPrice)
  if not price or price <= 0 or price > MAX_RANDOM_STARTING_GARAGE_PRICE then
    return false
  end
  return true
end

local function getRandomStartingGaragePool(levelName)
  local facilities = freeroam_facilities.getFacilities(levelName or getCurrentLevelIdentifier())
  local pool = {}
  if not facilities or type(facilities.garages) ~= "table" then
    return pool
  end
  for _, garage in ipairs(facilities.garages) do
    if isEligibleRandomStartingGarage(garage) then
      table.insert(pool, garage.id)
    end
  end
  return pool
end

local function pickRandomStartingGarageId(levelName)
  local pool = getRandomStartingGaragePool(levelName)
  if #pool == 0 then
    -- Fallback if a map has no ≤50k purchasable homes.
    return getDefaultStartingGarageId(levelName)
  end
  return pool[math.random(1, #pool)]
end

-- Resolve once and lock into career preference so teleport/grant stay stable.
local function resolveAndPersistRandomStartingGarage(levelName)
  local preference = getManualStartingGaragePreference()
  if preference.mode ~= "default" then
    return nil
  end
  if preference.garageId and preference.garageId ~= "" then
    return preference.garageId
  end

  local picked = pickRandomStartingGarageId(levelName)
  if not picked then
    return nil
  end

  if career_career and career_career.setStartingGaragePreference then
    career_career.setStartingGaragePreference("default", picked)
  end
  log("I", "garageManager", string.format(
    "Resolved random starting garage for %s: %s",
    tostring(levelName or getCurrentLevelIdentifier()),
    tostring(picked)))
  return picked
end

local function hasAnyPurchasedGarage()
  for _ in pairs(purchasedGarages) do
    return true
  end
  return false
end

local function getEffectiveStartingGarages(levelName)
  if career_challengeModes and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.startingGarages and #activeChallenge.startingGarages > 0 then
      return deepcopy(activeChallenge.startingGarages), "challenge"
    end
  end

  -- Hardcore never grants / teleports to a free starting garage.
  if isHardcoreMode() or (career_career and career_career.hardcoreMode) then
    return {}, "hardcore"
  end

  local preference = getManualStartingGaragePreference()
  if preference.mode == "none" then
    return {}, "none"
  end

  if preference.garageId and preference.garageId ~= "" then
    return {preference.garageId}, "specific"
  end

  -- Existing careers saved as default+nil already own their map starter (or none).
  -- Do not lock a new random pick mid-career — that would grant an extra free home
  -- on the next purchaseDefaultGarage / world-ready pass.
  if hasAnyPurchasedGarage() then
    local legacyId = getDefaultStartingGarageId(levelName)
    if legacyId then
      return {legacyId}, "default"
    end
    return {}, "default"
  end

  local randomGarageId = resolveAndPersistRandomStartingGarage(levelName)
  if randomGarageId then
    return {randomGarageId}, "random"
  end

  return {}, "default"
end

local function getPrimaryStartingGarageId(levelName)
  local garages = getEffectiveStartingGarages(levelName)
  return garages[1]
end

local function isEffectiveStartingGarage(garageId, levelName)
  if not garageId then return false end
  local effectiveStartingGarages = getEffectiveStartingGarages(levelName)
  for _, startingGarageId in ipairs(effectiveStartingGarages or {}) do
    if startingGarageId == garageId then
      return true
    end
  end
  return false
end

local function getGarageFacilityQuiet(garageId)
  if not garageId then return nil end
  local getFacilityIfExists = freeroam_facilities.getFacilityIfExists
    or function(type, id) return freeroam_facilities.getFacility(type, id, true) end
  return getFacilityIfExists("garage", garageId)
end

local function isGrantedStartingGarage(garageId, garage)
  if not garageId then return false end
  garage = garage or getGarageFacilityQuiet(garageId)
  if not garage or garage.starterGarage then return false end
  return isChallengeStartingGarage(garageId) or isManualStartingGarage(garageId)
end

local function isFreeStarterGarage(garageId, garage)
  garage = garage or getGarageFacilityQuiet(garageId)
  if not garage or not garage.starterGarage then return false end
  if isHardcoreMode() then
    return false
  end
  return isEffectiveStartingGarage(garageId)
end

local function inferLegacyAcquisition(garageId)
  local garage = getGarageFacilityQuiet(garageId)
  if not garage then
    return { type = "grant", amountPaid = 0 }
  end
  if isFreeStarterGarage(garageId, garage) or isGrantedStartingGarage(garageId, garage) then
    return { type = "grant", amountPaid = 0 }
  end
  local defaultPrice = math.max(0, math.floor(tonumber(garage.defaultPrice) or 0))
  if defaultPrice <= 0 then
    return { type = "grant", amountPaid = 0 }
  end
  return { type = "purchase", amountPaid = defaultPrice }
end

local function isStarterGaragePurchasable(garageId)
  if not garageId then return false end
  local garage = getGarageFacilityQuiet(garageId)
  if not garage or not garage.starterGarage then return false end
  if purchasedGarages[garageId] then return false end
  if isHardcoreMode() then
    return true
  end
  if isEffectiveStartingGarage(garageId) then
    return false
  end
  return true
end

local function reloadRecoveryPrompt()
  if core_recoveryPrompt then
    core_recoveryPrompt.addTowingButtons()
    core_recoveryPrompt.addTaxiButtons()
  end
end

local function buildGarageSizes()
  local garages = freeroam_facilities.getFacilitiesByType("garage")
  
  if garages then
    for _, garage in pairs(garages) do
      if isGarageForSale(garage.id) then
        garageSize[tostring(garage.id)] = nil
        goto continue
      end
      local isRented = career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garage.id)
      if purchasedGarages[garage.id] or isRented then
        garageSize[tostring(garage.id)] = (math.ceil(garage.capacity / (isHardcoreMode() and 2 or 1)) or 0)
      end
      ::continue::
    end
  end
end

local function addPurchasedGarage(garageId, acquisition)
  if isNotPurchasableGarage(garageId) then
    log("D", "garageManager", "Ignoring purchase of non-purchasable facility: " .. tostring(garageId))
    return
  end
  log("I", "garageManager", "Adding purchased garage: " .. garageId)
  purchasedGarages[garageId] = true
  discoveredGarages[garageId] = true
  clearRelinquishedGrant(garageId)
  setGarageAcquisition(garageId, acquisition)
  reloadRecoveryPrompt()
  buildGarageSizes()
end

local function addDiscoveredGarage(garageId)
  if not discoveredGarages[garageId] then
    local garage = getGarageFacilityQuiet(garageId)
    if garage and garage.defaultPrice == 0 and not garage.notPurchasable and not isRelinquishedGrant(garageId) then
      purchasedGarages[garageId] = true
      setGarageAcquisition(garageId, { type = "grant", amountPaid = 0 })
    end
    discoveredGarages[garageId] = true
    reloadRecoveryPrompt()
  end
end

local function purchaseDefaultGarage()
  if career_career.hardcoreMode or isHardcoreMode() then return end
  
  local effectiveStartingGarages, source = getEffectiveStartingGarages()
  if source == "challenge" then
    log("D", "garageManager", "purchaseDefaultGarage: Skipping default garage purchase - challenge has starting garages: " .. dumps(effectiveStartingGarages))
    return
  end

  local preference = getManualStartingGaragePreference()
  if preference.mode == "none" then
    log("D", "garageManager", "purchaseDefaultGarage: Skipping default garage purchase for manual starting garage mode: " .. tostring(preference.mode))
    return
  end

  local garageId = effectiveStartingGarages and effectiveStartingGarages[1] or preference.garageId
  if not garageId or garageId == "" then
    log("W", "garageManager", "purchaseDefaultGarage: No eligible starting garage resolved")
    return
  end

  if isRelinquishedGrant(garageId) then
    log("D", "garageManager", "purchaseDefaultGarage: Skipping re-grant of relinquished starting garage: " .. garageId)
    return
  end
  if purchasedGarages[garageId] then
    return
  end

  log("D", "garageManager", string.format(
    "purchaseDefaultGarage: Granting starting garage (%s): %s",
    tostring(source),
    tostring(garageId)))
  addPurchasedGarage(garageId, { type = "grant", amountPaid = 0 })
end

local function fillGarages()
  local vehicles = career_modules_inventory.getVehicles()
  local getFacilityIfExists = freeroam_facilities.getFacilityIfExists
    or function(type, id) return freeroam_facilities.getFacility(type, id, true) end

  for id, vehicle in pairs(vehicles) do
    local loc = vehicle.location
    local locOnCurrentMap = loc and getFacilityIfExists("garage", loc)

    if not loc then
      -- Only assign a garage that exists on this map (getNextAvailableSpace is filtered).
      career_modules_inventory.moveVehicleToGarage(id)
    elseif locOnCurrentMap and not vehicle.niceLocation then
      career_modules_inventory.moveVehicleToGarage(id, loc)
    elseif loc and not locOnCurrentMap then
      -- Keep cross-map ownership; do not reassign to a local garage just for a name.
      if not vehicle.niceLocation then
        vehicle.niceLocation = tostring(loc)
      end
    end
  end
end

local function loadPurchasedGarages()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  
  local filePath = currentSavePath .. "/career/rls_career/" .. saveFile
  local data = jsonReadFile(filePath) or {}
  purchasedGarages = data.garages or {}
  discoveredGarages = data.discovered or {}
  garageAcquisitions = data.acquisitions or {}
  relinquishedGrants = data.relinquishedGrants or {}

  -- Public tuning tents used to auto-own as free $0 garages. Strip leftover ownership.
  local saveDirty = false
  for garageId in pairs(purchasedGarages) do
    if isNotPurchasableGarage(garageId) then
      purchasedGarages[garageId] = nil
      clearGarageAcquisition(garageId)
      saveDirty = true
    end
  end
  if saveDirty then
    log("I", "garageManager", "Removed ownership of public tuning stations from save data")
  end

  -- Backfill acquisition metadata for older saves.
  for garageId, owned in pairs(purchasedGarages) do
    if owned and not garageAcquisitions[garageId] then
      setGarageAcquisition(garageId, inferLegacyAcquisition(garageId))
      saveDirty = true
    end
  end

  -- The recovery yard briefly reused commercialGarage. If that prototype
  -- generated contracts for a save, preserve access when moving the feature
  -- back to its dedicated recoveryYard facility. Keep commercialGarage owned
  -- as well because it is a real property and may have been purchased earlier.
  local migratedRecoveryYard = false
  local recoveryState = jsonReadFile(currentSavePath .. "/career/rls_career/offroadRecovery.json") or {}
  local usedCommercialRecoveryPrototype = (tonumber(recoveryState.nextId) or 1) > 1
  if usedCommercialRecoveryPrototype and purchasedGarages.commercialGarage and not purchasedGarages.recoveryYard then
    purchasedGarages.recoveryYard = true
    discoveredGarages.recoveryYard = true
    clearRelinquishedGrant("recoveryYard")
    if not garageAcquisitions.recoveryYard then
      setGarageAcquisition("recoveryYard", inferLegacyAcquisition("recoveryYard"))
    end
    migratedRecoveryYard = true
  elseif usedCommercialRecoveryPrototype and discoveredGarages.commercialGarage and not discoveredGarages.recoveryYard then
    discoveredGarages.recoveryYard = true
    migratedRecoveryYard = true
  end
  if migratedRecoveryYard then
    log("I", "garageManager", "Restored recoveryYard access from the commercialGarage recovery prototype")
    saveDirty = true
  end

  if career_career.hardcoreMode and not data.garages then
    purchasedGarages = {}
    discoveredGarages = {}
    garageAcquisitions = {}
    relinquishedGrants = {}
  end

  -- If we have an active challenge with starting garages, ensure they are purchased
  if career_challengeModes and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.startingGarages and #activeChallenge.startingGarages > 0 then
      log("D", "garageManager", "loadPurchasedGarages: Ensuring challenge starting garages are purchased: " .. dumps(activeChallenge.startingGarages))
      for _, garageId in ipairs(activeChallenge.startingGarages) do
        if isRelinquishedGrant(garageId) then
          log("D", "garageManager", "loadPurchasedGarages: Skipping relinquished challenge starting garage: " .. garageId)
        elseif not purchasedGarages[garageId] then
          log("D", "garageManager", "loadPurchasedGarages: Adding missing challenge starting garage: " .. garageId)
          purchasedGarages[garageId] = true
          discoveredGarages[garageId] = true
          setGarageAcquisition(garageId, { type = "grant", amountPaid = 0 })
          saveDirty = true
        elseif not garageAcquisitions[garageId] then
          setGarageAcquisition(garageId, { type = "grant", amountPaid = 0 })
          saveDirty = true
        end
      end
    end
  end

  local preference = getManualStartingGaragePreference()
  if preference.mode == "default" and preference.garageId and preference.garageId ~= "" then
    if isRelinquishedGrant(preference.garageId) then
      log("D", "garageManager", "loadPurchasedGarages: Skipping relinquished manually selected starting garage: " .. preference.garageId)
    elseif not purchasedGarages[preference.garageId] then
      log("D", "garageManager", "loadPurchasedGarages: Adding missing manually selected starting garage: " .. preference.garageId)
      purchasedGarages[preference.garageId] = true
      discoveredGarages[preference.garageId] = true
      setGarageAcquisition(preference.garageId, { type = "grant", amountPaid = 0 })
      saveDirty = true
    elseif not garageAcquisitions[preference.garageId] then
      setGarageAcquisition(preference.garageId, { type = "grant", amountPaid = 0 })
      saveDirty = true
    end
  end

  if saveDirty then
    savePurchasedGarages(currentSavePath)
  end

  reloadRecoveryPrompt()
  buildGarageSizes()
  fillGarages()
end

local function onCareerModulesActivated()
  loadPurchasedGarages()
end

local function onExtensionLoaded()
  loadPurchasedGarages()
  loadNegotiationCooldowns()
  buildGarageSizes()
end

local function calculateGaragePurchasePrice(garageId)
  if not garageId then
    return nil
  end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return nil
  end

  if not isHardcoreMode() and garage.starterGarage then
    if not isStarterGaragePurchasable(garageId) then
      return 0
    end
  end

  local price = garage.defaultPrice
  if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
    price = math.floor(price * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
  end
  return price
end

local function calculateClosingFee(price)
  if not price or price <= 0 then return 0 end
  return math.floor((price * CLOSING_FEE_RATE) + 0.5)
end

local function calculateAnnualPropertyTax(price)
  if not price or price <= 0 then return 0 end
  return math.floor((price * PROPERTY_TAX_RATE) + 0.5)
end

local function purchaseGarageWithFinancing(garage, purchasePrice, selectedTerm)
  if not garage or not career_modules_propertyMortgage then return false end
  if not career_modules_propertyMortgage.isMortgageAvailable or not career_modules_propertyMortgage.isMortgageAvailable() then
    return false
  end
  if not career_modules_payment then return false end

  local downPayment = career_modules_propertyMortgage.computeDownPayment(purchasePrice)
  if not downPayment then return false end

  local closingFee = calculateClosingFee(purchasePrice)
  local propertyTax = calculateAnnualPropertyTax(purchasePrice)
  local cashToClose = downPayment + closingFee + propertyTax

  if cashToClose > 0 then
    local paid = career_modules_payment.pay(
      { money = { amount = cashToClose, canBeNegative = false } },
      { label = "Closing on " .. garage.name }
    )
    if not paid then return false end
  end

  local mortgage = career_modules_propertyMortgage.createMortgage(garage.id, purchasePrice, selectedTerm, true)
  return mortgage ~= nil
end

-- Wrapper for backward compatibility
local function getGaragePrice(garage, computerId)
  local garageId
  if garage then
    garageId = type(garage) == "table" and garage.id or garage
  elseif computerId then
    local computer = freeroam_facilities.getFacility("computer", computerId)
    if computer then garageId = computer.garageId end
  end
  return calculateGaragePurchasePrice(garageId)
end

-- Complete purchase with negotiated price (called from realEstateNegotiation module)
local function completePurchaseWithNegotiatedPrice(garageId, finalPrice, freezePrice, useFinancing, selectedTerm)
  if not career_career.isActive() then 
    log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Career not active")
    return false 
  end
  
  if not garageId or not finalPrice then
    log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Missing garageId or finalPrice")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "completePurchaseWithNegotiatedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  garageToPurchase = garage
  setNegotiationCooldown(garageId)
  setPendingNegotiatedPrice(garageId, finalPrice)
  
  if freezePrice then
    freezeNegotiatedPrice(garageId, finalPrice)
  end
  
  local listingData = requestGarageListing(garageId)
  
  -- Always show the negotiated price on the listing, even if not frozen
  listingData.negotiatedPrice = finalPrice
  listingData.isFrozen = freezePrice == true
  local closingFee = calculateClosingFee(finalPrice)
  local propertyTax = calculateAnnualPropertyTax(finalPrice)
  listingData.closingFee = closingFee
  listingData.propertyTax = propertyTax
  listingData.estimatedTotal = finalPrice + closingFee + propertyTax
  
  listingData.useFinancing = useFinancing == true
  listingData.selectedTerm = selectedTerm
  pendingGarageListingData = listingData
  
  guihooks.trigger('openGarageListing', listingData)
  extensions.ui_router.navigate('garage-listing')
  
  return true
end

local function purchaseGarageAtNegotiatedPrice(garageId, useFinancing, selectedTerm)
  if not career_career.isActive() then 
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Career not active")
    return false 
  end
  
  if not garageId or type(garageId) ~= "string" or garageId == "" then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Invalid garageId (expected non-empty string)")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  local negotiatedPrice = getFrozenPrice(garageId)
  if not negotiatedPrice then
    negotiatedPrice = getPendingNegotiatedPrice(garageId)
  end
  if not negotiatedPrice then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: No negotiated price found")
    return false
  end
  
  if not career_modules_payment then
    log("E", "garageManager", "purchaseGarageAtNegotiatedPrice: Payment module not loaded")
    return false
  end

  local closingFee = calculateClosingFee(negotiatedPrice)
  local propertyTax = calculateAnnualPropertyTax(negotiatedPrice)

  local success = false
  if useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable() then
    success = purchaseGarageWithFinancing(garage, negotiatedPrice, selectedTerm)
  else
    local totalPrice = negotiatedPrice + closingFee + propertyTax
    local price = { money = { amount = totalPrice, canBeNegative = false } }
    success = career_modules_payment.pay(price, { label = "Purchased " .. garage.name })
  end

  if success then
    local financed = useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage
      and career_modules_propertyMortgage.hasMortgage(garage.id)
    addPurchasedGarage(garage.id, {
      type = financed and "finance" or "purchase",
      amountPaid = negotiatedPrice
    })
    clearFrozenPrice(garageId)
    clearPendingNegotiatedPrice(garageId)
    career_saveSystem.saveCurrent()
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'play'})
    return true
  end

  return false
end

-- Request garage listing data for UI (with negotiation support)
requestGarageListing = function(garageId)
  if not career_career.isActive() then return nil end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return nil end
  
  local listedPrice = getGaragePrice(garage)
  local canNegotiate = (not garage.starterGarage or isStarterGaragePurchasable(garageId)) and listedPrice > 0
  local ownerInfo = nil
  if career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
    ownerInfo = career_modules_propertyOwners.getOwnerForListing(garageId, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then
      listedPrice = ownerInfo.currentAskingPrice
    end
  end
  
  -- Get garage preview from computer preview if available
  local preview = garage.preview or ""
  local computers = freeroam_facilities.getFacilitiesByType("computer")
  if computers then
    for _, comp in pairs(computers) do
      if comp.garageId == garageId and comp.preview then
        preview = comp.preview
        break
      end
    end
  end
  
  -- Translate name if needed
  local name = garage.name
  if translateLanguage then
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then name = translated end
  end
  
  local negotiatedPrice = getFrozenPrice(garageId)
  if not negotiatedPrice then
    negotiatedPrice = getPendingNegotiatedPrice(garageId)
  end
  local effectivePrice = negotiatedPrice or listedPrice
  
  local closingFee = calculateClosingFee(effectivePrice)
  local propertyTax = calculateAnnualPropertyTax(effectivePrice)
  local estimatedTotal = effectivePrice + closingFee + propertyTax
  
  local canNegotiateNow, cooldownRemaining = canNegotiateGarage(garageId)
  canNegotiate = canNegotiate and canNegotiateNow

  local mortgageAvailableFlag = false
  local mortgageInfo = nil
  local creditTier = ""
  if career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable then
    mortgageAvailableFlag = career_modules_propertyMortgage.isMortgageAvailable()
    if mortgageAvailableFlag and career_modules_propertyMortgage.getMortgageOfferDetails then
      local details = career_modules_propertyMortgage.getMortgageOfferDetails()
      if details then
        local dpPct = details.downPaymentPercent or 0.2
        local downPayment = math.floor(effectivePrice * dpPct)
        mortgageInfo = {
          creditTier = details.tier or "",
          downPaymentPct = math.floor(dpPct * 100),
          downPayment = downPayment,
          cashToClose = downPayment + closingFee + propertyTax,
          interestRate = details.rate or 0,
          availableTerms = details.termsAvailable or {12, 24, 36, 48},
        }
      end
    end
  end
  if career_modules_credit and career_modules_credit.getTier then
    local tier = career_modules_credit.getTier()
    if tier then creditTier = tier.label end
  end

  local rentalBreakdown = nil
  if career_modules_propertyRentals and career_modules_propertyRentals.getRentalBreakdown then
    rentalBreakdown = career_modules_propertyRentals.getRentalBreakdown(garageId)
  end

  local data = {
    garageId = garage.id,
    name = name,
    preview = preview,
    listedPrice = listedPrice,
    negotiatedPrice = negotiatedPrice,
    closingFee = closingFee,
    propertyTax = propertyTax,
    estimatedTotal = estimatedTotal,
    capacity = math.ceil(garage.capacity / (isHardcoreMode() and 2 or 1)),
    parkingSpots = (garage.parkingSpotNames and #garage.parkingSpotNames) or 0,
    neighborhood = "West Coast",
    canNegotiate = canNegotiate,
    cooldownRemaining = cooldownRemaining,
    isFrozen = getFrozenPrice(garageId) ~= nil,
    starterGarage = (garage.starterGarage and not isStarterGaragePurchasable(garageId)) or false,
    ownerInfo = ownerInfo,
    ownerName = ownerInfo and ownerInfo.name or nil,
    ownerArchetype = ownerInfo and ownerInfo.archetype or nil,
    mortgageAvailable = mortgageAvailableFlag,
    mortgageInfo = mortgageInfo,
    creditTier = creditTier,
    rentalBreakdown = rentalBreakdown,
  }
  
  return data
end

-- Start negotiation for a garage purchase
local function startGarageNegotiation(garageId)
  if not career_career.isActive() then return false end
  if not career_modules_realEstateNegotiation then
    log("E", "garageManager", "realEstateNegotiation module not loaded")
    return false
  end
  
  local canNegotiateNow, cooldownRemaining = canNegotiateGarage(garageId)
  if not canNegotiateNow then
    log("W", "garageManager", "Negotiation on cooldown for garage: " .. tostring(garageId))
    return false
  end
  
  return career_modules_realEstateNegotiation.startNegotiateBuying(garageId)
end

-- Purchase garage at listed price (no negotiation)
local function purchaseGarageAtListedPrice(garageId, useFinancing, selectedTerm)
  if not career_career.isActive() then 
    log("E", "garageManager", "purchaseGarageAtListedPrice: Career not active")
    return false 
  end
  
  if not garageId or type(garageId) ~= "string" or garageId == "" then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Invalid garageId (expected non-empty string)")
    return false
  end
  
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Garage not found: " .. tostring(garageId))
    return false
  end
  
  local listedPrice = getGaragePrice(garage)
  if not listedPrice then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Could not determine price for garage: " .. tostring(garageId))
    return false
  end
  
  if career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
    local ownerInfo = career_modules_propertyOwners.getOwnerForListing(garageId, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then
      listedPrice = ownerInfo.currentAskingPrice
    end
  end
  
  -- Free garages (starter garages)
  if listedPrice == 0 then
    addPurchasedGarage(garage.id, { type = "grant", amountPaid = 0 })
    career_saveSystem.saveCurrent()
    
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    if computers then
      for _, computer in pairs(computers) do
        if computer.garageId == garageId then
          career_modules_computer.openComputerMenuById(computer.id)
          break
        end
      end
    end
    
    return true
  end
  
  -- Paid garages
  if not career_modules_payment then
    log("E", "garageManager", "purchaseGarageAtListedPrice: Payment module not loaded")
    return false
  end

  local closingFee = calculateClosingFee(listedPrice)
  local propertyTax = calculateAnnualPropertyTax(listedPrice)

  local success = false
  local financed = false
  if useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable() then
    success = purchaseGarageWithFinancing(garage, listedPrice, selectedTerm)
    financed = success
  else
    local totalPrice = listedPrice + closingFee + propertyTax
    local priceTable = { money = { amount = totalPrice, canBeNegative = false } }
    success = career_modules_payment.pay(priceTable, { label = "Purchased " .. garage.name })
  end

  if success then
    addPurchasedGarage(garage.id, {
      type = financed and "finance" or "purchase",
      amountPaid = listedPrice
    })
    career_saveSystem.saveCurrent()
    guihooks.trigger('toastrMsg', {type="success", title="Property Purchased", msg="Welcome to your new garage!"})
    guihooks.trigger('ChangeState', {state = 'play'})
    return true
  end

  return false
end

local function getPendingGarageListing()
  local data = pendingGarageListingData
  pendingGarageListingData = nil
  return data
end

local function showPurchaseGaragePrompt(garageId)
  if not career_career.isActive() then return end
  if not garageId or type(garageId) ~= "string" or garageId == "" then return end
  if isNotPurchasableGarage(garageId) then return end

  -- Rented garages: treat as accessible, open computer directly
  if career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garageId) then
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    local computerId = nil
    for _, computer in pairs(computers) do
      if computer.garageId == garageId then
        computerId = computer.id
        break
      end
    end
    if computerId then
      career_modules_computer.openComputerMenuById(computerId)
    end
    return
  end

  garageToPurchase = freeroam_facilities.getFacility("garage", garageId)
  
  -- Free garages (starter garages) - purchase immediately
  if getGaragePrice(garageToPurchase) == 0 then
    addPurchasedGarage(garageToPurchase.id, { type = "grant", amountPaid = 0 })
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    local computerId = nil
    for _, computer in pairs(computers) do
      if computer.garageId == garageId then
        computerId = computer.id
        break
      end
    end
    if computerId then
      career_modules_computer.openComputerMenuById(computerId)
    end
    career_saveSystem.saveCurrent()
    return
  end
  
  -- Paid garages - show listing view with negotiation option
  pendingGarageListingData = requestGarageListing(garageId)
  guihooks.trigger('openGarageListing', pendingGarageListingData)
  extensions.ui_router.navigate('garage-listing')
end

local function requestGarageData()
  local garage = garageToPurchase
  if garage then
    if translateLanguage(garage.name, garage.name, true) then
      garage.name = translateLanguage(garage.name, garage.name, true)
    end
    local price = getGaragePrice(garage)
    local closingFee = calculateClosingFee(price)
    local propertyTax = calculateAnnualPropertyTax(price)
    local garageData = {
      name = garage.name,
      price = price,
      capacity = math.ceil(garage.capacity / (isHardcoreMode() and 2 or 1)),
      closingFeeRate = CLOSING_FEE_RATE,
      propertyTaxRate = PROPERTY_TAX_RATE,
      closingFee = closingFee,
      propertyTax = propertyTax,
      estimatedTotal = price + closingFee + propertyTax
    }
    return garageData
  end
  return nil
end

local function canPay(overriddenTotal)
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end
  local totalPrice = tonumber(overriddenTotal)
  if not totalPrice or totalPrice <= 0 then
    return false
  end
  totalPrice = math.floor(totalPrice + 0.5)
  local currentMoney = career_modules_playerAttributes.getAttributeValue("money")
  return currentMoney >= totalPrice
end

local function buyGarage(overriddenTotal, useFinancing, selectedTerm)
  if not garageToPurchase then
    return false
  end

  local listedPrice = getGaragePrice(garageToPurchase)
  if not listedPrice then
    garageToPurchase = nil
    return false
  end
  
  if career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
    local ownerInfo = career_modules_propertyOwners.getOwnerForListing(garageToPurchase.id, listedPrice)
    if ownerInfo and ownerInfo.currentAskingPrice then
      listedPrice = ownerInfo.currentAskingPrice
    end
  end

  local negotiatedPrice = getFrozenPrice(garageToPurchase.id)
  if not negotiatedPrice then
    negotiatedPrice = getPendingNegotiatedPrice(garageToPurchase.id)
  end
  local effectivePrice = negotiatedPrice or listedPrice
  
  local closingFee = calculateClosingFee(effectivePrice)
  local propertyTax = calculateAnnualPropertyTax(effectivePrice)
  local totalPrice = effectivePrice + closingFee + propertyTax
  local overrideAmount = tonumber(overriddenTotal)
  if overrideAmount and overrideAmount > 0 then
    totalPrice = math.floor(overrideAmount + 0.5)
  end

  local success = false
  local financed = false
  if useFinancing and career_modules_propertyMortgage and career_modules_propertyMortgage.isMortgageAvailable and career_modules_propertyMortgage.isMortgageAvailable() then
    success = purchaseGarageWithFinancing(garageToPurchase, effectivePrice, selectedTerm)
    financed = success
  else
    local price = { money = { amount = totalPrice, canBeNegative = false } }
    success = career_modules_payment.pay(price, { label = "Purchased " .. garageToPurchase.name })
  end

  if success then
    addPurchasedGarage(garageToPurchase.id, {
      type = financed and "finance" or "purchase",
      amountPaid = effectivePrice
    })
    if negotiatedPrice then
      clearFrozenPrice(garageToPurchase.id)
      clearPendingNegotiatedPrice(garageToPurchase.id)
    end
    career_saveSystem.saveCurrent()
    guihooks.trigger('ChangeState', {state = 'play'})
    garageToPurchase = nil
    return true
  end

  garageToPurchase = nil
  return false
end

local function cancelGaragePurchase()
  if garageToPurchase then
    clearPendingNegotiatedPrice(garageToPurchase.id)
  end
  guihooks.trigger('ChangeState', {state = 'play'})
  garageToPurchase = nil
end

local function getStoredLocations()
  local vehicles = career_modules_inventory.getVehicles()
  local storedLocation = {}
  for id, vehicle in pairs(vehicles) do -- Builds stored location table
      if vehicle.location then
          if not storedLocation[vehicle.location] then
              storedLocation[vehicle.location] = {}
          end
          table.insert(storedLocation[vehicle.location], id) -- Adds vehicle to location
      end
  end
  return storedLocation
end

local function getVehiclesInGarage(garageId)
  if not garageId then return {} end
  local storedLocation = getStoredLocations()
  return storedLocation[garageId] or {}
end

local function removePurchasedGarage(garageId)
  if not garageId then return false end
  if not purchasedGarages[garageId] then return false end

  purchasedGarages[garageId] = nil
  discoveredGarages[garageId] = nil
  clearGarageAcquisition(garageId)
  reloadRecoveryPrompt()
  buildGarageSizes()
  career_saveSystem.saveCurrent()
  return true
end

local function getGarageCapacityData()
  buildGarageSizes()
  local storedLocation = getStoredLocations()
  local data = {}

  for garageId, owned in pairs(purchasedGarages) do
    if owned and not isGarageForSale(garageId) then
      local garage = freeroam_facilities.getFacility("garage", garageId)
      local capacity = garageSize[tostring(garageId)]
      if not capacity and garage and garage.capacity then
        capacity = math.ceil(garage.capacity / (isHardcoreMode() and 2 or 1))
      end
      local vehiclesInGarage = storedLocation[garageId]
      local count = vehiclesInGarage and #vehiclesInGarage or 0

      data[tostring(garageId)] = {
        id = garageId,
        name = garage and garage.name or tostring(garageId),
        capacity = capacity or 0,
        count = count
      }
    end
  end

  return data
end

local function getPurchasedGarages()
  local result = {}
  for garageId, _ in pairs(purchasedGarages) do
    table.insert(result, garageId)
  end
  return result
end

local function countUnlocatedInventoryVehicles()
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles then return 0 end
  local count = 0
  for _, vehicle in pairs(vehicles) do
    if not vehicle.location and not vehicle.takesNoInventorySpace then
      count = count + 1
    end
  end
  return count
end

local function isGarageSpace(garage)
  if isGarageForSale(garage) then return {false, 0} end
  if not garageSize[garage] then
    buildGarageSizes()
    if not garageSize[garage] then return {false, 0} end
  end
  local storedLocation = getStoredLocations()

  local carsInGarage
  if not storedLocation[garage] or storedLocation[garage] == {} then
    carsInGarage = 0
  else
    carsInGarage = #storedLocation[garage]
  end
  return {(garageSize[garage] - carsInGarage) > 0, garageSize[garage] - carsInGarage}
end

local function getFreeSlots()
  local totalCapacity = 0
  for garage, owned in pairs(purchasedGarages) do
    if not owned then goto continue end
    if isGarageForSale(garage) then goto continue end
    local space = isGarageSpace(garage)
    if space[1] then
      totalCapacity = totalCapacity + space[2]
    end
    ::continue::
  end
  if career_modules_propertyRentals and career_modules_propertyRentals.getActiveRentals then
    for garageId, _ in pairs(career_modules_propertyRentals.getActiveRentals()) do
      if not purchasedGarages[garageId] and not isGarageForSale(garageId) then
        local space = isGarageSpace(garageId)
        if space[1] then
          totalCapacity = totalCapacity + space[2]
        end
      end
    end
  end
  return math.max(0, totalCapacity - countUnlocatedInventoryVehicles())
end

local function getGarageAvailabilityReason()
  if getFreeSlots() > 0 then
    return "ok"
  end

  for garageId, owned in pairs(purchasedGarages) do
    if owned and not isGarageForSale(garageId) then
      return "full"
    end
  end

  if career_modules_propertyRentals and career_modules_propertyRentals.getActiveRentals then
    for garageId, _ in pairs(career_modules_propertyRentals.getActiveRentals()) do
      if not isGarageForSale(garageId) then
        return "full"
      end
    end
  end

  return "none"
end

local function garageIdToName(garageId)
  local getFacilityIfExists = freeroam_facilities.getFacilityIfExists
    or function(type, id) return freeroam_facilities.getFacility(type, id, true) end
  local garage = getFacilityIfExists("garage", garageId)
  if garage then
    return garage.name
  end
  return garageId and tostring(garageId) or nil
end

local function computerIdToGarageId(computerId)
  local computer = freeroam_facilities.getFacility("computer", computerId)
  if computer then
    return computer.garageId
  end
  return nil
end

local function getGaragePurchasePrice(garageId)
  return calculateGaragePurchasePrice(garageId)
end

-- Legacy function for garage selling (applies 0.75 multiplier for sell-back price)
-- DO NOT use for purchase price - use getGaragePurchasePrice instead
local function getGarageSellPrice(garageId, computerId)
  if not garageId and not computerId then
    return nil
  elseif not garageId and computerId then
    garageId = computerIdToGarageId(computerId)
  end
  if not garageId then
    return nil
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if garage then
    if isGrantedStartingGarage(garageId, garage) then
      log("D", "garageManager", "getGarageSellPrice: Garage " .. garageId .. " is granted as a starting garage, sell price: " .. garage.defaultPrice)
      return tonumber(garage.defaultPrice)
    end

    local price = isFreeStarterGarage(garageId, garage) and 0 or garage.defaultPrice
    -- Apply housing market index if available
    if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
      price = math.floor(price * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
    end
    log("D", "garageManager", "getGarageSellPrice: Garage " .. garageId .. " sell price: " .. price .. " (starterGarage: " .. tostring(garage.starterGarage) .. ")")
    return math.floor(tonumber(price) * 0.75 + 0.5)
  end
  return nil
end

local function canSellGarageByGarageId(garageId)
  if not garageId then
    return false
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return false
  end

  -- Granted / unpaid ownership cannot be sold for money.
  if isGrantedGarageOwnership(garageId) then
    return {false, 0}
  end
  
  local space = isGarageSpace(garageId)
  local capacity = math.ceil(garage.capacity / (isHardcoreMode() and 2 or 1))
  return {space[2] == capacity, capacity - space[2]}
end

local function canMoveOutOfGarage(garageId)
  if not garageId then
    return {false, 0, "invalid"}
  end
  if not purchasedGarages[garageId] then
    return {false, 0, "notOwned"}
  end
  if not isGrantedGarageOwnership(garageId) then
    return {false, 0, "purchased"}
  end
  if career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage and career_modules_propertyRentals.isRentedGarage(garageId) then
    return {false, 0, "rented"}
  end
  if isGarageForSale(garageId) then
    return {false, 0, "listed"}
  end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return {false, 0, "missing"}
  end

  local space = isGarageSpace(garageId)
  local capacity = math.ceil((garage.capacity or 0) / (isHardcoreMode() and 2 or 1))
  local vehicleCount = capacity - (space and space[2] or 0)
  if vehicleCount < 0 then vehicleCount = 0 end
  if not space or space[2] ~= capacity then
    return {false, vehicleCount, "vehicles"}
  end

  return {true, 0, nil}
end

local function canMoveOutOfGarageByComputerId(computerId)
  local garageId = computerIdToGarageId(computerId)
  return canMoveOutOfGarage(garageId)
end

local function moveOutOfGarage(garageId)
  if not career_career.isActive() then return false end
  local canMove = canMoveOutOfGarage(garageId)
  if not canMove or not canMove[1] then
    if canMove and canMove[3] == "vehicles" then
      guihooks.trigger('toastrMsg', {
        type = "error",
        title = "Cannot Move Out",
        msg = "Remove all vehicles from this garage first."
      })
    end
    return false
  end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  local wasGrant = isGrantedGarageOwnership(garageId)
  purchasedGarages[garageId] = nil
  clearGarageAcquisition(garageId)
  -- Keep discovered so the property can be reclaimed/bought later.
  discoveredGarages[garageId] = true
  if wasGrant then
    markRelinquishedGrant(garageId)
  end
  reloadRecoveryPrompt()
  buildGarageSizes()
  career_saveSystem.saveCurrent()
  guihooks.trigger('garageListingsUpdated')
  guihooks.trigger('toastrMsg', {
    type = "success",
    title = "Moved Out",
    msg = wasGrant
      and ("You no longer have access to " .. ((garage and garage.name) or tostring(garageId)) .. ". You can reclaim it for free from Real Estate.")
      or ("You no longer have access to " .. ((garage and garage.name) or tostring(garageId)) .. ".")
  })
  return true
end

local function canReclaimGrantedGarage(garageId)
  if not garageId or not career_career.isActive() then
    return false
  end
  if purchasedGarages[garageId] then
    return false
  end
  if not isRelinquishedGrant(garageId) then
    return false
  end
  if isNotPurchasableGarage(garageId) then
    return false
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then
    return false
  end
  if career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage
      and career_modules_propertyRentals.isRentedGarage(garageId) then
    return false
  end
  return true
end

local function reclaimGrantedGarage(garageId)
  if not canReclaimGrantedGarage(garageId) then
    return false
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  addPurchasedGarage(garageId, { type = "grant", amountPaid = 0 })
  career_saveSystem.saveCurrent()
  guihooks.trigger('garageListingsUpdated')
  guihooks.trigger('toastrMsg', {
    type = "success",
    title = "Reclaimed",
    msg = "You reclaimed access to " .. ((garage and garage.name) or tostring(garageId)) .. "."
  })
  return true
end

local function moveOutOfGarageByComputerId(computerId)
  return moveOutOfGarage(computerIdToGarageId(computerId))
end

local function canSellGarage(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then
    return false
  end
  return canSellGarageByGarageId(garageId)
end

local function listGarageForSale(computerId, askingPrice)
  if not career_career.isActive() then return false end

  local garageId = computerIdToGarageId(computerId)
  if not garageId then
    return false
  end

  local canSellInfo = canSellGarage(computerId)
  if not canSellInfo or not canSellInfo[1] then
    return false
  end

  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.listPropertyForSale then
    log("E", "garageManager", "listPropertyForSale is not available")
    return false
  end

  local marketPrice = getGaragePurchasePrice(garageId) or 0
  local desiredPrice = tonumber(askingPrice) or marketPrice
  if desiredPrice <= 0 then
    return false
  end

  if career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage and career_modules_propertyMortgage.hasMortgage(garageId) then
    if not career_modules_propertyMortgage.canSellMortgagedProperty(garageId, desiredPrice) then
      guihooks.trigger('toastrMsg', {type="error", title="Sale Blocked", msg="Asking price must exceed remaining mortgage balance."})
      return false
    end
  end

  return career_modules_realEstateNegotiation.listPropertyForSale(garageId, desiredPrice)
end

local function listGarageForSaleByGarageId(garageId, askingPrice)
  if not career_career.isActive() then return false end
  if not garageId then return false end

  local canSellInfo = canSellGarageByGarageId(garageId)
  if not canSellInfo or not canSellInfo[1] then
    return false
  end

  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.listPropertyForSale then
    log("E", "garageManager", "listPropertyForSale is not available")
    return false
  end

  local marketPrice = getGaragePurchasePrice(garageId) or 0
  local desiredPrice = tonumber(askingPrice) or marketPrice
  if desiredPrice <= 0 then
    return false
  end

  if career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage and career_modules_propertyMortgage.hasMortgage(garageId) then
    if not career_modules_propertyMortgage.canSellMortgagedProperty(garageId, desiredPrice) then
      guihooks.trigger('toastrMsg', {type="error", title="Sale Blocked", msg="Asking price must exceed remaining mortgage balance."})
      return false
    end
  end

  return career_modules_realEstateNegotiation.listPropertyForSale(garageId, desiredPrice)
end

local function sellGarage(computerId, sellPrice)
  -- Legacy API kept for compatibility: now routes to listing flow.
  return listGarageForSale(computerId, sellPrice)
end

local function completePropertySaleFromListing(garageId, finalPrice, buyerPersonality)
  if not career_career.isActive() then return false end
  if not garageId or not finalPrice then return false end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return false end
  if not purchasedGarages[garageId] then return false end

  local payoutAmount = finalPrice
  if career_modules_propertyMortgage and career_modules_propertyMortgage.hasMortgage and career_modules_propertyMortgage.hasMortgage(garageId) then
    if not career_modules_propertyMortgage.canSellMortgagedProperty(garageId, finalPrice) then
      guihooks.trigger('toastrMsg', {type="error", title="Sale Blocked", msg="Sale price does not cover remaining mortgage balance."})
      return false
    end

    local processed, netProceeds = career_modules_propertyMortgage.processMortgageSale(garageId, finalPrice)
    if not processed then
      return false
    end
    payoutAmount = netProceeds or 0
  end

  purchasedGarages[garageId] = nil
  discoveredGarages[garageId] = nil
  clearGarageAcquisition(garageId)
  reloadRecoveryPrompt()
  buildGarageSizes()

  local soldMessage = "Sold " .. (garage.name or tostring(garageId))
  career_modules_payment.reward({ money = { amount = payoutAmount } }, { label = soldMessage }, true)

  if career_modules_propertyOwners and career_modules_propertyOwners.registerOwnerFromSale then
    career_modules_propertyOwners.registerOwnerFromSale(garageId, finalPrice, buyerPersonality)
  end

  if career_modules_realEstateNegotiation and career_modules_realEstateNegotiation.removePropertyListing then
    career_modules_realEstateNegotiation.removePropertyListing(garageId)
  end

  career_saveSystem.saveCurrent()
  guihooks.trigger('garageListingsUpdated')
  return true
end

local function getGarageListingPriceGuidance(computerId, askingPrice)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPriceGuidanceForListing then
    return nil
  end
  return career_modules_realEstateNegotiation.getPriceGuidanceForListing(garageId, askingPrice)
end

local function getGarageListingPriceGuidanceByGarageId(garageId, askingPrice)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPriceGuidanceForListing then
    return nil
  end
  return career_modules_realEstateNegotiation.getPriceGuidanceForListing(garageId, askingPrice)
end

local function getGarageActiveListing(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPropertyListing then
    return nil
  end
  return career_modules_realEstateNegotiation.getPropertyListing(garageId)
end

local function removeGarageListing(computerId)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return false end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.removePropertyListing then
    return false
  end
  return career_modules_realEstateNegotiation.removePropertyListing(garageId)
end

local function startGarageSellingNegotiation(computerId, offerIndex)
  local garageId = computerIdToGarageId(computerId)
  if not garageId then return false end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.startNegotiateSelling then
    return false
  end
  return career_modules_realEstateNegotiation.startNegotiateSelling(garageId, offerIndex)
end

local function getNextAvailableSpace()
  local getFacilityIfExists = freeroam_facilities.getFacilityIfExists
    or function(type, id) return freeroam_facilities.getFacility(type, id, true) end

  for garage, owned in pairs(purchasedGarages) do
    if not owned then goto continue end
    if not getFacilityIfExists("garage", garage) then goto continue end
    if isGarageForSale(garage) then goto continue end
    if isGarageSpace(garage)[1] then
      return garage
    end
    ::continue::
  end
  if career_modules_propertyRentals and career_modules_propertyRentals.getActiveRentals then
    for garageId, _ in pairs(career_modules_propertyRentals.getActiveRentals()) do
      if not purchasedGarages[garageId]
        and getFacilityIfExists("garage", garageId)
        and isGarageSpace(garageId)[1] then
        return garageId
      end
    end
  end
  return nil
end

local function onWorldReadyState(state)
  if state == 2 and career_career.isActive() then
    buildGarageSizes()
    fillGarages()
    purchaseDefaultGarage()
  end
end

M.onWorldReadyState = onWorldReadyState

M.purchaseDefaultGarage = purchaseDefaultGarage

M.showPurchaseGaragePrompt = showPurchaseGaragePrompt
M.requestGarageData = requestGarageData
M.canPay = canPay
M.buyGarage = buyGarage
M.cancelGaragePurchase = cancelGaragePurchase
M.getGaragePrice = getGaragePrice
M.getGaragePurchasePrice = getGaragePurchasePrice

-- Real estate negotiation integration
M.completePurchaseWithNegotiatedPrice = completePurchaseWithNegotiatedPrice
M.purchaseGarageAtNegotiatedPrice = purchaseGarageAtNegotiatedPrice
M.freezeNegotiatedPrice = freezeNegotiatedPrice
M.requestGarageListing = requestGarageListing
M.getPendingGarageListing = getPendingGarageListing
M.startGarageNegotiation = startGarageNegotiation
M.purchaseGarageAtListedPrice = purchaseGarageAtListedPrice
M.canNegotiateGarage = canNegotiateGarage
M.setNegotiationCooldown = setNegotiationCooldown
M.canSellGarage = canSellGarage
M.canMoveOutOfGarage = canMoveOutOfGarage
M.canMoveOutOfGarageByComputerId = canMoveOutOfGarageByComputerId
M.moveOutOfGarage = moveOutOfGarage
M.moveOutOfGarageByComputerId = moveOutOfGarageByComputerId
M.canReclaimGrantedGarage = canReclaimGrantedGarage
M.reclaimGrantedGarage = reclaimGrantedGarage
M.isGrantedGarageOwnership = isGrantedGarageOwnership
M.wasGaragePurchasedWithMoney = wasGaragePurchasedWithMoney
M.getGarageAcquisition = getGarageAcquisition
M.listGarageForSale = listGarageForSale
M.listGarageForSaleByGarageId = listGarageForSaleByGarageId
M.sellGarage = sellGarage
M.completePropertySaleFromListing = completePropertySaleFromListing
M.getGarageListingPriceGuidance = getGarageListingPriceGuidance
M.getGarageListingPriceGuidanceByGarageId = getGarageListingPriceGuidanceByGarageId
M.getGarageActiveListing = getGarageActiveListing
M.removeGarageListing = removeGarageListing
M.startGarageSellingNegotiation = startGarageSellingNegotiation

local function getOwnedGaragesListingData()
  local result = {}
  local storedLocation = getStoredLocations()
  local included = {}

  local function addGarageListingEntry(garageId, opts)
    if included[garageId] then return end
    local garage = freeroam_facilities.getFacility("garage", garageId)
    if not garage or garage.notPurchasable then return end

    local isRented = opts and opts.isRented == true
    local capacity = math.ceil((garage.capacity or 0) / (isHardcoreMode() and 2 or 1))
    local vehiclesInGarage = storedLocation[garageId]
    local vehicleCount = vehiclesInGarage and #vehiclesInGarage or 0

    local preview = garage.preview or ""
    local computers = freeroam_facilities.getFacilitiesByType("computer")
    if computers then
      for _, comp in pairs(computers) do
        if comp.garageId == garageId and comp.preview then
          preview = comp.preview
          break
        end
      end
    end

    local name = garage.name or tostring(garageId)
    if translateLanguage then
      local translated = translateLanguage(garage.name, garage.name, true)
      if translated then name = translated end
    end

    local marketValue = garage.defaultPrice or 0
    if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
      marketValue = math.floor(marketValue * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
    end
    local isReclaimable = opts and opts.canReclaim == true
    local isStarter = (not isReclaimable) and isFreeStarterGarage(garageId, garage)
    local isGranted = (not isRented) and (not isReclaimable) and isGrantedGarageOwnership(garageId)
    local canSellInfo = (not isRented) and (not isReclaimable) and canSellGarageByGarageId(garageId) or nil
    local canSell = canSellInfo and canSellInfo[1] or false
    local canMoveInfo = (not isRented) and (not isReclaimable) and canMoveOutOfGarage(garageId) or nil
    local canMoveOut = canMoveInfo and canMoveInfo[1] or false
    local moveOutBlockedReason = canMoveInfo and canMoveInfo[3] or nil

    local listing = nil
    local offerCount = 0
    local askingPrice = nil
    if not isRented and not isReclaimable and career_modules_realEstateNegotiation and career_modules_realEstateNegotiation.getPropertyListing then
      listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
      if listing then
        askingPrice = listing.askingPrice
        offerCount = listing.offers and #listing.offers or 0
      end
    end

    local computerId = nil
    if computers then
      for _, comp in pairs(computers) do
        if comp.garageId == garageId then
          computerId = comp.id
          break
        end
      end
    end

    local rentalInfo = nil
    if isRented and career_modules_propertyRentals and career_modules_propertyRentals.getRentalInfo then
      rentalInfo = career_modules_propertyRentals.getRentalInfo(garageId)
    end

    local acquisition = (not isReclaimable) and getGarageAcquisition(garageId) or nil

    included[garageId] = true
    table.insert(result, {
      garageId = garageId,
      computerId = computerId,
      name = name,
      preview = preview,
      capacity = capacity,
      vehicleCount = isReclaimable and 0 or vehicleCount,
      marketValue = marketValue,
      isStarter = isStarter,
      isGranted = isGranted,
      canSell = canSell,
      canMoveOut = canMoveOut,
      moveOutBlockedReason = moveOutBlockedReason,
      canReclaim = isReclaimable,
      amountPaid = acquisition and acquisition.amountPaid or 0,
      acquisitionType = acquisition and acquisition.type or nil,
      isListed = listing ~= nil,
      askingPrice = askingPrice,
      offerCount = offerCount,
      neighborhood = "West Coast",
      isRented = isRented,
      rentalType = rentalInfo and rentalInfo.type or nil,
      paymentsRemaining = rentalInfo and rentalInfo.paymentsRemaining or nil,
    })
  end

  for garageId, owned in pairs(purchasedGarages) do
    if owned then
      addGarageListingEntry(garageId, { isRented = false })
    end
  end

  if career_modules_propertyRentals and career_modules_propertyRentals.getActiveRentals then
    for garageId, _ in pairs(career_modules_propertyRentals.getActiveRentals()) do
      if not purchasedGarages[garageId] then
        addGarageListingEntry(garageId, { isRented = true })
      end
    end
  end

  for garageId, flagged in pairs(relinquishedGrants) do
    if flagged and canReclaimGrantedGarage(garageId) then
      addGarageListingEntry(garageId, { canReclaim = true })
    end
  end

  return result
end

local function getGarageOffersData(garageId)
  if not garageId then return nil end
  if not career_modules_realEstateNegotiation or not career_modules_realEstateNegotiation.getPropertyListing then
    return nil
  end

  local listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
  if not listing then return nil end

  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return nil end

  local preview = garage.preview or ""
  local computers = freeroam_facilities.getFacilitiesByType("computer")
  if computers then
    for _, comp in pairs(computers) do
      if comp.garageId == garageId and comp.preview then
        preview = comp.preview
        break
      end
    end
  end

  local name = garage.name or tostring(garageId)
  if translateLanguage then
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then name = translated end
  end

  local marketValue = garage.defaultPrice or 0
  if career_modules_globalEconomy and career_modules_globalEconomy.getHousingMarketIndex then
    marketValue = math.floor(marketValue * career_modules_globalEconomy.getHousingMarketIndex() + 0.5)
  end

  local offers = {}
  if listing.offers then
    for i, offer in ipairs(listing.offers) do
      table.insert(offers, {
        index = i,
        value = offer.value,
        negotiatedPrice = offer.negotiatedPrice,
        buyerName = offer.buyerPersonality and offer.buyerPersonality.name or "Buyer",
        timestamp = offer.timestamp,
        negotiationPossible = offer.negotiationPossible ~= false,
      })
    end
  end

  return {
    garageId = garageId,
    name = name,
    preview = preview,
    askingPrice = listing.askingPrice,
    marketValue = marketValue,
    offers = offers,
  }
end

local function acceptOffer(garageId, offerIndex)
  if not garageId or not offerIndex then return false end
  if not career_modules_realEstateNegotiation then return false end

  local listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
  if not listing or not listing.offers then return false end

  local idx = tonumber(offerIndex)
  if not idx or idx < 1 or idx > #listing.offers then return false end

  local offer = listing.offers[idx]
  if not offer then return false end

  local salePrice = offer.negotiatedPrice or offer.value
  return completePropertySaleFromListing(garageId, salePrice, offer.buyerPersonality)
end

local function declineOffer(garageId, offerIndex)
  if not garageId or not offerIndex then return false end
  if not career_modules_realEstateNegotiation then return false end

  local listing = career_modules_realEstateNegotiation.getPropertyListing(garageId)
  if not listing or not listing.offers then return false end

  local idx = tonumber(offerIndex)
  if not idx or idx < 1 or idx > #listing.offers then return false end

  table.remove(listing.offers, idx)
  return true
end

M.getOwnedGaragesListingData = getOwnedGaragesListingData
M.getGarageOffersData = getGarageOffersData
M.acceptOffer = acceptOffer
M.declineOffer = declineOffer

M.getFreeSlots = getFreeSlots
M.getGarageAvailabilityReason = getGarageAvailabilityReason
M.onCareerModulesActivated = onCareerModulesActivated
M.onExtensionLoaded = onExtensionLoaded
M.isPurchasedGarage = isPurchasedGarage
M.isAccessibleGarage = isAccessibleGarage
M.isNotPurchasableGarage = isNotPurchasableGarage
M.getPurchasedGarages = getPurchasedGarages
M.addPurchasedGarage = addPurchasedGarage
M.addDiscoveredGarage = addDiscoveredGarage
M.isDiscoveredGarage = isDiscoveredGarage
M.loadPurchasedGarages = loadPurchasedGarages
M.savePurchasedGarages = savePurchasedGarages
M.onSaveCurrentProfile = onSaveCurrentProfile
M.garageIdToName = garageIdToName
M.computerIdToGarageId = computerIdToGarageId

-- Localization
M.isGarageSpace = isGarageSpace
M.getNextAvailableSpace = getNextAvailableSpace
M.getEffectiveStartingGarages = getEffectiveStartingGarages
M.getPrimaryStartingGarageId = getPrimaryStartingGarageId
M.buildGarageSizes = buildGarageSizes
M.fillGarages = fillGarages
M.getStoredLocations = getStoredLocations
M.getGarageCapacityData = getGarageCapacityData
M.getVehiclesInGarage = getVehiclesInGarage
M.removePurchasedGarage = removePurchasedGarage
M.isGarageForSale = isGarageForSale
M.isStarterGaragePurchasable = isStarterGaragePurchasable

return M
