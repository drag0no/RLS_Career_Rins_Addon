local M = {}

M.dependencies = {
  'career_career',
  'career_modules_finiteDamage',
}

local config = nil
local configLevelId = nil

local activeInventoryId = nil
local activeTriggerName = nil

local function currentLevelId()
  if getCurrentLevelIdentifier then
    return getCurrentLevelIdentifier()
  end
  return nil
end

local function configPathForLevel(levelId)
  return levelId and ("/levels/" .. levelId .. "/facilities/roadsideService.json") or nil
end

local function loadConfig(force)
  local levelId = currentLevelId()
  if not force and config and configLevelId == levelId then
    return config
  end

  configLevelId = levelId
  local path = configPathForLevel(levelId)
  config = (path and jsonReadFile(path)) or {}
  if not config.default then
    config.default = {services = {"repair", "maintenance", "tuning"}, laborMultiplier = 1.25}
  end
  if not config.spots then
    config.spots = {}
  end
  return config
end

local function prettySpotName(triggerName)
  local base = tostring(triggerName or ""):gsub("_?repairSpot$", ""):gsub("_", " ")
  if base == "" then
    return "Service Spot"
  end
  return base:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
end

local function getSpotConfig(triggerName)
  loadConfig()
  local spotCfg = config.spots[triggerName]
  local defaultName = prettySpotName(triggerName)
  if spotCfg then
    return {
      services = spotCfg.services or config.default.services,
      laborMultiplier = spotCfg.laborMultiplier or config.default.laborMultiplier or 1.25,
      name = spotCfg.name or defaultName,
    }
  end
  return {
    services = config.default.services or {"repair", "maintenance", "tuning"},
    laborMultiplier = config.default.laborMultiplier or 1.25,
    name = defaultName,
  }
end

local function hasService(triggerName, serviceName)
  local spotCfg = getSpotConfig(triggerName)
  for _, svc in ipairs(spotCfg.services or {}) do
    if svc == serviceName then return true end
  end
  return false
end

local function isCareerActive()
  return career_career and career_career.isActive and career_career.isActive()
end

local function getVehicleRecord(inventoryId)
  if not career_modules_inventory or not career_modules_inventory.getVehicles then
    return nil
  end
  local vehicles = career_modules_inventory.getVehicles() or {}
  return vehicles[tonumber(inventoryId)] or vehicles[tostring(inventoryId)]
end

local function buildVehicleSummary(inventoryId)
  local vehicle = getVehicleRecord(inventoryId)
  if not vehicle then
    return nil
  end

  local niceName = nil
  if career_modules_inventory and career_modules_inventory.getVehicleNiceNameTranslated then
    local ok, result = pcall(career_modules_inventory.getVehicleNiceNameTranslated, inventoryId)
    if ok then niceName = result end
  end

  return {
    niceName = niceName or vehicle.niceName or vehicle.model or "Vehicle",
    model = vehicle.model,
    mileage = tonumber(vehicle.mileage) or 0,
  }
end

local function getPlayerMoney()
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    return career_modules_playerAttributes.getAttributeValue("money") or 0
  end
  return 0
end

local function isMaintenanceEnabled()
  return career_modules_maintenanceMode and career_modules_maintenanceMode.isEnabled and
           career_modules_maintenanceMode.isEnabled() == true
end

local function ensureFiniteDamage()
  if career_modules_finiteDamage then
    return career_modules_finiteDamage
  end
  pcall(function()
    if extensions and extensions.load then
      extensions.load("career_modules_finiteDamage")
    end
  end)
  return career_modules_finiteDamage
end

local function getBrokenPartsCount(inventoryId)
  local vehicle = getVehicleRecord(inventoryId)
  if not vehicle or not vehicle.partConditions then
    return 0
  end
  if career_modules_valueCalculator and career_modules_valueCalculator.getNumberOfBrokenParts then
    return career_modules_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions) or 0
  end
  return 0
end

local function vehicleNeedsRoadsideRepair(inventoryId)
  local finite = ensureFiniteDamage()
  if finite and finite.hasRepairableDamage then
    return finite.hasRepairableDamage(inventoryId)
  end
  return getBrokenPartsCount(inventoryId) > 0
end

local function laborMultiplierForQuote(spotCfg, hasBrokenParts)
  local laborMult = tonumber(spotCfg.laborMultiplier) or 1.25
  -- Finite-only jobs stay cheap: lighter labor bump than full part-replace jobs.
  if not hasBrokenParts then
    laborMult = math.min(laborMult, 1.1)
  end
  return laborMult
end

local function buildRepairData(inventoryId)
  local vehicle = getVehicleRecord(inventoryId)
  if not vehicle then
    return {available = false, reason = "Vehicle not found."}
  end

  -- Fully broken parts (stock replace price) plus finite soft damage / cosmetics / tires.
  -- Do not require insurance "needs repair" (≥3 broken) so spots can fix small damage.
  local finite = ensureFiniteDamage()
  local assessment = finite and finite.assess and finite.assess(inventoryId) or nil
  if not assessment or not assessment.hasDamage then
    return {available = false, reason = (assessment and assessment.reason) or "No damage to repair."}
  end

  local baseCost = tonumber(assessment.totalPreLabor) or 0
  local spotCfg = getSpotConfig(activeTriggerName)
  local laborMult = laborMultiplierForQuote(spotCfg, assessment.hasBrokenParts == true)
  local adjustedCost = math.ceil(baseCost * laborMult)

  return {
    available = true,
    baseCost = baseCost,
    laborMultiplier = laborMult,
    totalCost = adjustedCost,
    canAfford = getPlayerMoney() >= adjustedCost,
    hasTireDamage = assessment.hasTireDamage == true,
    hasFiniteDamage = assessment.hasFiniteDamage == true,
    hasBrokenParts = assessment.hasBrokenParts == true,
    brokenParts = tonumber(assessment.brokenParts) or 0,
    brokenPartsCost = tonumber(assessment.brokenPartsCost) or 0,
    finiteCost = tonumber(assessment.finiteCost) or 0,
    finiteMinimum = tonumber(assessment.finiteMinimum) or 40,
    damageLines = assessment.lines or {},
  }
end

local function buildUiData()
  if not activeInventoryId then
    return {error = "No vehicle selected."}
  end

  local spotCfg = getSpotConfig(activeTriggerName)
  local vehicleSummary = buildVehicleSummary(activeInventoryId)

  local services = {}
  for _, svc in ipairs(spotCfg.services or {}) do
    if svc == "repair" then
      local repairData = buildRepairData(activeInventoryId) or {}
      services.repair = {
        id = "repair",
        label = "Repair",
        description = "Fix vehicle damage",
        available = repairData.available == true,
        reason = repairData.reason,
        cost = tonumber(repairData.totalCost) or 0,
        canAfford = repairData.canAfford == true,
        laborMultiplier = tonumber(repairData.laborMultiplier) or 1.25,
        hasBrokenParts = repairData.hasBrokenParts == true,
        hasFiniteDamage = repairData.hasFiniteDamage == true,
        hasTireDamage = repairData.hasTireDamage == true,
        brokenParts = tonumber(repairData.brokenParts) or 0,
        brokenPartsCost = tonumber(repairData.brokenPartsCost) or 0,
        finiteCost = tonumber(repairData.finiteCost) or 0,
        finiteMinimum = tonumber(repairData.finiteMinimum) or 40,
        damageLines = repairData.damageLines or {},
      }
    elseif svc == "maintenance" then
      local maintEnabled = isMaintenanceEnabled()
      services.maintenance = {
        id = "maintenance",
        label = "Maintenance",
        description = "Service fluids and check vehicle systems",
        available = maintEnabled,
        reason = not maintEnabled and "Maintenance mode is disabled." or nil,
      }
    elseif svc == "tuning" then
      -- At spots that also repair, block tuning while damaged so players can't
      -- open tuning for the free minor-damage auto-fix (incl. soft/tire damage).
      local mustRepairFirst = hasService(activeTriggerName, "repair")
        and vehicleNeedsRoadsideRepair(activeInventoryId)
      services.tuning = {
        id = "tuning",
        label = "Tuning",
        description = "Adjust suspension, alignment, and more",
        available = not mustRepairFirst,
        reason = mustRepairFirst and "Repair the vehicle first." or nil,
      }
    end
  end

  return {
    inventoryId = tostring(activeInventoryId),
    triggerName = activeTriggerName,
    spotName = spotCfg.name,
    vehicle = vehicleSummary,
    services = services,
    playerMoney = getPlayerMoney(),
    laborMultiplier = tonumber(spotCfg.laborMultiplier) or 1.25,
  }
end

local function getUiData()
  local success, result = xpcall(buildUiData, debug.traceback)
  if success then return result end
  if log then log("E", "roadsideServiceComputer", tostring(result)) end
  return {error = "Failed to load service data.", debugError = tostring(result)}
end

local function refundRepair(amount, inventoryId)
  if not amount or amount <= 0 then
    return
  end
  if career_modules_payment and career_modules_payment.pay then
    career_modules_payment.pay(
      {money = {amount = -amount, canBeNegative = true}},
      {label = "Roadside repair refund: id " .. tostring(inventoryId)}
    )
  elseif career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({money = amount}, {tags = {"roadsideRepairRefund"}, label = "Roadside repair refund"})
  end
end

local function performRepair()
  if not activeInventoryId or not activeTriggerName then
    return {ok = false, message = "No vehicle or service station selected."}
  end

  if not hasService(activeTriggerName, "repair") then
    return {ok = false, message = "Repair not available at this location."}
  end

  local finite = ensureFiniteDamage()
  if not finite or not finite.quoteSelection or not finite.applySelection then
    return {ok = false, message = "Repair system unavailable."}
  end

  -- Always repair everything on the quote — no per-part selection.
  local quote = finite.quoteSelection(activeInventoryId, nil)
  if not quote or not quote.ok then
    return {ok = false, message = (quote and quote.message) or "Nothing to repair."}
  end

  local spotCfg = getSpotConfig(activeTriggerName)
  local laborMult = laborMultiplierForQuote(spotCfg, quote.hasBrokenParts == true)
  local cost = math.ceil((tonumber(quote.totalPreLabor) or 0) * laborMult)
  if cost <= 0 then
    return {ok = false, message = "Nothing to repair."}
  end
  if getPlayerMoney() < cost then
    return {ok = false, message = "Not enough money."}
  end

  local inventoryId = activeInventoryId
  if career_modules_payment and career_modules_payment.pay then
    career_modules_payment.pay(
      {money = {amount = cost, canBeNegative = false}},
      {label = "Roadside repair: id " .. tostring(inventoryId)}
    )
  elseif career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({money = -cost}, {tags = {"roadsideRepair"}, label = "Roadside repair"})
  else
    return {ok = false, message = "Payment system unavailable."}
  end

  if Engine and Engine.Audio and Engine.Audio.playOnce then
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  local applied = finite.applySelection(inventoryId, nil)
  if not applied or not applied.ok then
    refundRepair(cost, inventoryId)
    return {ok = false, message = (applied and applied.message) or "Unable to complete repair."}
  end
  local failedCost = 0
  for _, line in ipairs(applied.failedLines or {}) do
    failedCost = failedCost + (tonumber(line.cost) or 0)
  end
  if failedCost > 0 then
    refundRepair(math.min(cost, math.ceil(failedCost * laborMult)), inventoryId)
  end

  local function afterRefresh()
    -- Stay on the Roadside Service menu after an in-place repair.
  end

  if ui_fadeScreen and ui_fadeScreen.start then
    ui_fadeScreen.start(0.5)
  end

  if career_modules_inventory and career_modules_inventory.spawnVehicle
    and career_modules_inventory.getVehicleIdFromInventoryId
    and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
    career_modules_inventory.spawnVehicle(inventoryId, 2, function()
      afterRefresh()
      if ui_fadeScreen and ui_fadeScreen.stop then
        ui_fadeScreen.stop(0.5)
      end
    end)
  else
    afterRefresh()
    if ui_fadeScreen and ui_fadeScreen.stop then
      ui_fadeScreen.stop(0.5)
    end
  end

  return {ok = true, cost = cost, message = "Vehicle repaired."}
end

local function openMaintenance()
  if not activeInventoryId or not activeTriggerName then
    return {ok = false, message = "No vehicle or service station selected."}
  end

  if not hasService(activeTriggerName, "maintenance") then
    return {ok = false, message = "Maintenance not available at this location."}
  end

  if not isMaintenanceEnabled() then
    return {ok = false, message = "Maintenance mode is disabled."}
  end

  if career_modules_maintenanceComputer and career_modules_maintenanceComputer.openMenuFromComputer then
    career_modules_maintenanceComputer.openMenuFromComputer(activeInventoryId, nil, "roadside-service")
    return {ok = true}
  end

  return {ok = false, message = "Maintenance system unavailable."}
end

local function openTuning()
  if not activeInventoryId or not activeTriggerName then
    return {ok = false, message = "No vehicle or service station selected."}
  end

  if not hasService(activeTriggerName, "tuning") then
    return {ok = false, message = "Tuning not available at this location."}
  end

  if hasService(activeTriggerName, "repair") and vehicleNeedsRoadsideRepair(activeInventoryId) then
    return {ok = false, message = "Repair the vehicle first."}
  end

  if not career_modules_tuning or not career_modules_tuning.start then
    return {ok = false, message = "Tuning system unavailable."}
  end

  -- Third arg is returnRoute: back from tuning returns to Roadside Service.
  career_modules_tuning.start(activeInventoryId, nil, "roadside-service")
  return {ok = true}
end

local function openMenu(inventoryId, triggerName)
  log("I", "roadsideServiceComputer", string.format("openMenu called: invId=%s, trigger=%s", tostring(inventoryId), tostring(triggerName)))
  
  if not isCareerActive() then
    log("W", "roadsideServiceComputer", "Career not active, cannot open menu")
    return false
  end
  
  activeInventoryId = tonumber(inventoryId)
  activeTriggerName = triggerName
  
  if not activeInventoryId then
    log("W", "roadsideServiceComputer", "No valid inventory ID")
    return false
  end
  
  log("I", "roadsideServiceComputer", "Navigating to roadside-service route")
  extensions.ui_router.navigate('roadside-service')
  return true
end

local function closeMenu()
  activeInventoryId = nil
  activeTriggerName = nil
  if career_career and career_career.closeAllMenus then
    career_career.closeAllMenus()
  end
end

local function getActiveInventoryId()
  return activeInventoryId
end

local function getActiveTriggerName()
  return activeTriggerName
end

M.loadConfig = loadConfig
M.getSpotConfig = getSpotConfig
M.hasService = hasService
M.openMenu = openMenu
M.closeMenu = closeMenu
M.getUiData = getUiData
M.performRepair = performRepair
M.openMaintenance = openMaintenance
M.openTuning = openTuning
M.getActiveInventoryId = getActiveInventoryId
M.getActiveTriggerName = getActiveTriggerName
M.onClientStartMission = function() loadConfig(true) end

return M
