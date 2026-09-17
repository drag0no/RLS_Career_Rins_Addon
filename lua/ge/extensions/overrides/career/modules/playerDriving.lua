-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {'career_career', 'gameplay_walk'}

local playerData = {maxTrafficAmount = 0, maxParkingAmount = 0, defaultTrafficAmount = 1, trafficActive = 0}
local tutorialTrafficRestoreActive = nil
local tutorialParkingRestoreActive = nil
local trafficSetupInProgress = false
local testTrafficAmounts = {
  traffic = 1,
  police = 0,
  parkedCars = 1,
  active = 1
}

M.ensureTraffic = false
M.preStart = true
M.debugMode = not shipping_build

local function getPlayerData()
  return playerData
end

local function setPlayerData(newId, oldId)
  playerData.isParked = gameplay_parking.getCurrentParkingSpot(newId) and true or false

  if oldId then
    gameplay_parking.disableTracking(oldId)
  end
  if not gameplay_walk.isWalking() then
    gameplay_parking.enableTracking(newId)
  end

  if not gameplay_traffic.getTrafficData()[newId] then
    gameplay_traffic.insertTraffic(newId, true)
  end

  playerData.traffic = gameplay_traffic.getTrafficData()[newId]
  playerData.parking = gameplay_parking.getTrackingData()[newId]
end

local function isPoliceLoanerVehicle(vehId)
  if not vehId or not career_modules_loanerVehicles or not career_modules_loanerVehicles.getLoaningOrgsOfVehicle then
    return false
  end
  local loaningOrgs = career_modules_loanerVehicles.getLoaningOrgsOfVehicle(vehId)
  if not loaningOrgs then
    return false
  end
  for orgId, _ in pairs(loaningOrgs) do
    local id = tostring(orgId or "")
    if id == "policeLoaner" or id == "policeWork"
        or string.find(id, "PoliceLoaner", 1, true) or string.find(id, "PoliceWork", 1, true) then
      return true
    end
  end
  return false
end

local function getPlayerIsCop(switchCtx)
  switchCtx = switchCtx or {}
  local vehId = be:getPlayerVehicleID(0)
  if vehId and gameplay_traffic.getTrafficData()[vehId] and career_modules_inventory.getInventoryIdFromVehicleId(vehId) then
    local invId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
    local trafficVehicle = gameplay_traffic.getTrafficData()[vehId]
    local certifiedRole = career_modules_inventory.getVehicleRole(invId)
    local certifiedPolice = certifiedRole == 'police' or isPoliceLoanerVehicle(vehId)

    local pursuitMode = trafficVehicle.pursuit and trafficVehicle.pursuit.mode or 0
    if pursuitMode == 0 and switchCtx.switchOldId then
      local oldTraffic = gameplay_traffic.getTrafficData()[switchCtx.switchOldId]
      if oldTraffic and oldTraffic.pursuit then
        pursuitMode = oldTraffic.pursuit.mode or 0
      end
    end

    -- Certified / loaner police stay on duty; clear residual pursuit heat instead of
    -- demoting them to suspect (that made AI backup treat the player as the chase target).
    if certifiedPolice then
      -- Repo plates keep normal police targeting; check before role mutations.
      local licenseText = career_modules_inventory.getLicensePlateText(vehId)
      if licenseText and licenseText:lower() == "repo" then
        return false
      end
      if trafficVehicle then
        trafficVehicle:setRole('police')
        trafficVehicle.ignorePolice = true
        if trafficVehicle.pursuit and (trafficVehicle.pursuit.mode ~= 0 or (trafficVehicle.pursuit.score or 0) > 0) then
          if gameplay_police and gameplay_police.setPursuitMode then
            gameplay_police.setPursuitMode(0, vehId)
          else
            trafficVehicle.pursuit.mode = 0
            trafficVehicle.pursuit.score = 0
          end
        end
      end
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = true
      })
      return true
    end

    if pursuitMode ~= 0 then
      if pursuitMode > 0 and trafficVehicle.role and trafficVehicle.role.name ~= 'suspect' then
        trafficVehicle:setRole('suspect')
        if overhaul_extensionManager and overhaul_extensionManager.applyOverrideAI then
          overhaul_extensionManager.applyOverrideAI(vehId)
        end
      end
      local licenseText = career_modules_inventory.getLicensePlateText(vehId)
      if licenseText and licenseText:lower() == "repo" then
        return false
      end
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = false
      })
      return false
    end
    local vehicleRole = career_modules_inventory.getVehicleRole(invId)
    if vehicleRole ~= nil then
      if trafficVehicle then
        trafficVehicle:setRole(vehicleRole)
      end
    end
    local licenseText = career_modules_inventory.getLicensePlateText(vehId)
    if licenseText and licenseText:lower() == "repo" then
      return false
    end
    local role = gameplay_traffic.getTrafficData()[vehId].role.name
    if role == 'police' then
      if trafficVehicle then
        trafficVehicle:setRole('standard')
      end
      if switchCtx.switchOldId ~= nil then
        ui_message("This vehicle is not certified for police work", 8, "Police", "info")
      end
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = false
      })
      return false
    else
      gameplay_traffic.setTrafficVars({
        enableRandomEvents = false
      })
      return false
    end
  end
  return false
end

local function setTrafficVars()
  local spawnValue = clamp(6 / math.max(6, gameplay_traffic.getTrafficAmount(true)), 0.1, 1)
  gameplay_traffic.setTrafficVars({enableRandomEvents = false, spawnValue = spawnValue})
  gameplay_police.setPursuitVars({arrestRadius = 15, evadeTime = 40})
  gameplay_parking.setParkingVars({precision = 0.2})
end

-- Vanilla taxi registers its reserved vehicles during onTrafficSpecialVehiclesProviders.
-- Career loads traffic before gameplay_taxi is pulled in, so hail can spawn a car with
-- no provider/UI state unless we load the extension and refresh after traffic is ready.
local function ensureVanillaTaxiReady()
  if extensions and extensions.load and not extensions.isExtensionLoaded("gameplay_taxi") then
    pcall(extensions.load, "gameplay_taxi")
  end
  if not gameplay_taxi then return false end
  if gameplay_traffic.getState() == "on" then
    if gameplay_taxi.onTrafficStarted then
      gameplay_taxi.onTrafficStarted()
    end
    if gameplay_taxi.onTrafficSpecialVehiclesProviders then
      gameplay_taxi.onTrafficSpecialVehiclesProviders()
    end
  end
  return true
end

local function isNoPoliceModActive()
  if career_career.hardcoreMode or (career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode and career_modules_difficultyMode.isHardcoreMode()) then
    return false
  end
  if career_modules_policePreference and career_modules_policePreference.isEnabled then
    return not career_modules_policePreference.isEnabled()
  end
  if career_career.policeEnabled ~= nil then
    return not career_career.policeEnabled
  end
  return false
end

local function isNoParkedModActive()
  return overhaul_settings.getSetting('noParkedMode')
end

local function getFallbackTrafficAmounts()
  local trafficAmount = settings.getValue('trafficAmount')
  if trafficAmount == 0 then
    trafficAmount = gameplay_traffic.getIdealSpawnAmount()
  end
  if not getAllVehiclesByType()[1] then
    trafficAmount = trafficAmount - 1
  end
  if not M.debugMode then
    if isNoParkedModActive() then
      trafficAmount = clamp(trafficAmount, 5, 50)
    else
      trafficAmount = clamp(trafficAmount, 2, 50)
    end
  end

  local parkingAmount = settings.getValue('trafficParkedAmount')
  if isNoParkedModActive() then
    parkingAmount = 0
  else
    if parkingAmount == 0 then
      parkingAmount = clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 20)
    end
    if not M.debugMode then
      parkingAmount = clamp(parkingAmount, 2, 50)
    end
  end

  return trafficAmount, parkingAmount
end

local function setupTraffic(forceSetup)
  -- Several 0.39 career lifecycle hooks can arrive during the same level load.
  -- setupTrafficHelper is asynchronous, so maxTrafficAmount is still zero while
  -- later hooks run; without a lock each hook starts another complete batch.
  if trafficSetupInProgress then return end
  if not forceSetup and playerData.maxTrafficAmount > 0 then return end
  if forceSetup and gameplay_traffic.getState() == "on" and gameplay_traffic.getTrafficAmount() > 0 then
    M.ensureTraffic = false
    return
  end

  log("I", "career", "Now spawning traffic for career mode")
  if core_gamestate.loading() then core_gamestate.requestEnterLoadingScreen('careerVehicles') end

  local restrict = settings.getValue('trafficRestrictForCareer')
  if shipping_build then restrict = false end

  local trafficAmount, parkingAmount = getFallbackTrafficAmounts()
  if restrict then
    trafficAmount, parkingAmount = testTrafficAmounts.traffic, testTrafficAmounts.parkedCars
  end

  playerData.trafficActive = restrict and testTrafficAmounts.active or trafficAmount
  if playerData.trafficActive == 0 then
    playerData.trafficActive = math.huge
  end
  playerData.desiredParkingAmount = parkingAmount

  local trafficOptions = {
    simpleVehs = true,
    autoLoadFromFile = true,
    police = not isNoPoliceModActive()
  }
  trafficSetupInProgress = true
  local ok, err = xpcall(function()
    local spawnTrafficAmount = trafficAmount > 0 and (gameplay_vehicleRotationPool and gameplay_vehicleRotationPool.getPoolSpawnAmount(trafficAmount) or trafficAmount) or 0
    local spawnParkingAmount = parkingAmount > 0 and (gameplay_vehicleRotationPool and gameplay_vehicleRotationPool.getPoolSpawnAmount(parkingAmount) or parkingAmount) or 0
    gameplay_traffic.setupTrafficHelper(spawnTrafficAmount, trafficOptions, spawnParkingAmount, nil)
    gameplay_traffic.setActiveAmount(trafficAmount)
    gameplay_parking.setActiveAmount(parkingAmount)
    setTrafficVars()
  end, debug.traceback)
  if not ok then
    trafficSetupInProgress = false
    error(err, 0)
  end
  M.ensureTraffic = false
end

local function onSettingsChanged()
  if not career_career or not career_career.isActive or not career_career.isActive() then return end
  if career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive() then return end

  local trafficAmount, parkingAmount = getFallbackTrafficAmounts()
  local restrict = settings.getValue('trafficRestrictForCareer')
  if shipping_build then restrict = false end
  if restrict then
    trafficAmount, parkingAmount = testTrafficAmounts.traffic, testTrafficAmounts.parkedCars
  end

  playerData.trafficActive = restrict and testTrafficAmounts.active or trafficAmount
  if playerData.trafficActive == 0 then
    playerData.trafficActive = math.huge
  end
  playerData.desiredParkingAmount = parkingAmount

  if gameplay_traffic.getState() == "on" then
    gameplay_traffic.setActiveAmount(playerData.trafficActive)
  end

  if gameplay_parking.getState() then
    gameplay_parking.setActiveAmount(parkingAmount)
    if gameplay_parking.syncParkedCount then
      gameplay_parking.syncParkedCount()
    end
  end
end

local function setPoliceProbability(value)
  for id, tData in pairs(gameplay_traffic.getTrafficData()) do
    if tData.role.name == "police" then
      tData.activeProbability = value
      if value == 0 then
        local veh = getObjectByID(id)
        if veh then
          veh:setActive(0)
        end
      end
    end
  end
end

local function playerPursuitActive()
  return playerData.traffic and playerData.traffic.pursuit and playerData.traffic.pursuit.mode ~= 0
end

local function resetPlayerState()
  setPlayerData(be:getPlayerVehicleID(0))
  setTrafficVars()
  if playerData.traffic then
    playerData.traffic:resetAll()
  end
end

local function setTrafficForTutorial()
  gameplay_parking.scatterParkedCars()
  gameplay_parking.setActiveAmount(0)
  gameplay_traffic.scatterTraffic()
  gameplay_traffic.setActiveAmount(playerData.maxTrafficAmount)
  setPoliceProbability(0)
end

local function setTrafficAfterTutorial()
  gameplay_parking.scatterParkedCars()
  gameplay_traffic.scatterTraffic()
  resetPlayerState()
  setPoliceProbability(isNoPoliceModActive() and 0 or 0.15)
end

local function cacheTutorialTrafficRestoreAmounts()
  if tutorialTrafficRestoreActive == nil then
    tutorialTrafficRestoreActive = gameplay_traffic.getTrafficVars().activeAmount
  end
  if tutorialParkingRestoreActive == nil then
    tutorialParkingRestoreActive = gameplay_parking.getParkingVars().activeAmount
  end
end

local function restoreTrafficAfterTutorialPhase()
  local trafficAmount, parkedAmount = tutorialTrafficRestoreActive, tutorialParkingRestoreActive
  local fallbackTraffic, fallbackParked = getFallbackTrafficAmounts()
  if not trafficAmount or trafficAmount <= 0 then trafficAmount = fallbackTraffic end
  if not parkedAmount or parkedAmount <= 0 then parkedAmount = fallbackParked end

  if gameplay_traffic.getState() == "off" then
    gameplay_traffic.toggle(true)
  end

  gameplay_traffic.setActiveAmount(trafficAmount)
  gameplay_parking.setActiveAmount(parkedAmount)

  setTrafficAfterTutorial()
end

local function retrieveFavoriteVehicle()
  local inventory = career_modules_inventory
  local favoriteVehicleInventoryId = inventory.getFavoriteVehicle()
  if not favoriteVehicleInventoryId then
    return
  end
  local vehInfo = inventory.getVehicles()[favoriteVehicleInventoryId]
  if not vehInfo then
    return
  end

  local routePrice = 0
  local targetPos
  local existingVehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
  local existingVeh = existingVehId and getObjectByID(existingVehId)
  if existingVeh then
    targetPos = existingVeh:getPosition()
  elseif vehInfo.location then
    local garage = freeroam_facilities.getFacility("garage", vehInfo.location)
    targetPos = garage and freeroam_facilities.getGaragePosRot(garage) or nil
  end
  if targetPos and career_modules_quickTravel and career_modules_quickTravel.getPriceForQuickTravel then
    routePrice = career_modules_quickTravel.getPriceForQuickTravel(targetPos) or 0
  end
  inventory.useVehicleRetrievalService(
    favoriteVehicleInventoryId, routePrice, "Retrieved favorite vehicle with towing service")

  local vehId = existingVehId
  if vehId then
    local playerVehObj = getPlayerVehicle(0)
    spawn.safeTeleport(getObjectByID(vehId), playerVehObj:getPosition(), quatFromDir(playerVehObj:getDirectionVector()),
      nil, nil, nil, nil, false)
    core_vehicleBridge.executeAction(getObjectByID(vehId), 'setIgnitionLevel', 0)
  elseif not vehInfo.timeToAccess and not career_modules_insurance_insurance.inventoryVehNeedsRepair(favoriteVehicleInventoryId) then
    inventory.spawnVehicle(favoriteVehicleInventoryId, nil, function()
      local playerVehObj = getPlayerVehicle(0)
      local vehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
      spawn.safeTeleport(getObjectByID(vehId), playerVehObj:getPosition(),
        quatFromDir(playerVehObj:getDirectionVector()), nil, nil, nil, nil, false)
    end)
  end
end

local function getFavoriteVehicleRetrievalPrice()
  local inventory = career_modules_inventory
  local inventoryId = inventory and inventory.getFavoriteVehicle and inventory.getFavoriteVehicle()
  if not inventoryId then return {} end
  local vehInfo = inventory.getVehicles()[inventoryId]
  if not vehInfo then return {} end

  local targetPos
  local vehId = inventory.getVehicleIdFromInventoryId(inventoryId)
  local veh = vehId and getObjectByID(vehId)
  if veh then
    targetPos = veh:getPosition()
  elseif vehInfo.location then
    local garage = freeroam_facilities.getFacility("garage", vehInfo.location)
    targetPos = garage and freeroam_facilities.getGaragePosRot(garage) or nil
  end
  local routePrice = targetPos and career_modules_quickTravel and
    career_modules_quickTravel.getPriceForQuickTravel(targetPos) or 0
  local quote = inventory.getVehicleRetrievalQuote(inventoryId, routePrice)
  if quote.coveredByInsurance then return {} end
  return {money = {amount = quote.cost, canBeNegative = true}}
end

local function deleteTrailers(veh)
  local trailerData = core_trailerRespawn.getTrailerData()
  local trailerDataThisVeh = trailerData[veh:getId()]

  if trailerDataThisVeh then
    local trailer = getObjectByID(trailerDataThisVeh.trailerId)
    deleteTrailers(trailer)
    career_modules_inventory.removeVehicleObject(career_modules_inventory.getInventoryIdFromVehicleId(
      trailerDataThisVeh.trailerId))
  end
end

local teleportTrailerJob = function(job)
  local args = job.args[1]
  local vehicle = getObjectByID(args.vehicleId)
  local trailer = getObjectByID(args.trailerId)
  local vehRot = quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation())
  local vehBB = vehicle:getSpawnWorldOOBB()
  local vehBBCenter = vehBB:getCenter()

  local trailerBB = vehicle:getSpawnWorldOOBB()

  spawn.safeTeleport(trailer, vehBBCenter - vehicle:getDirectionVector() *
    (vehBB:getHalfExtents().y + trailerBB:getHalfExtents().y), vehRot, nil, nil, nil, true, args.resetVeh)

  core_trailerRespawn.getTrailerData()[args.vehicleId] = nil
end

local function teleportToGarage(garageId, veh, resetVeh)
  freeroam_facilities.teleportToGarage(garageId, veh, resetVeh)
  freeroam_bigMapMode.navigateToMission(nil)
  core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)

  local trailerData = core_trailerRespawn.getTrailerData()
  local primaryTrailerData = trailerData[veh:getId()]
  if primaryTrailerData then
    local teleportArgs = {
      trailerId = primaryTrailerData.trailerId,
      vehicleId = veh:getId(),
      resetVeh = resetVeh
    }
    core_jobsystem.create(teleportTrailerJob, 0.1, teleportArgs)

    career_modules_inventory.updatePartConditionsOfSpawnedVehicles(function()
      local trailer = getObjectByID(primaryTrailerData.trailerId)
      deleteTrailers(trailer)
      career_modules_fuel.minimumRefuelingCheck(veh:getId())
    end)
  else
    career_modules_fuel.minimumRefuelingCheck(veh:getId())
  end
end

local function onVehicleParkingStatus(vehId, data)
  if not gameplay_missions_missionManager.getForegroundMissionId() and not career_modules_tutorial.isActive() and vehId == be:getPlayerVehicleID(0) then
    if data.event == "valid" then
      if not playerData.isParked then
        playerData.isParked = true
      end
    elseif data.event == "exit" then
      playerData.isParked = false
    end
  end
end

local function onTrafficStarted()
  local updateAmount = playerData.maxTrafficAmount == 0
  if not career_career.tutorialEnabled and not gameplay_missions_missionManager.getForegroundMissionId() then
    updateAmount = true
    resetPlayerState()
    setPoliceProbability(isNoPoliceModActive() and 0 or 0.15)
    if playerData.trafficActive and playerData.trafficActive > 0 then
      gameplay_traffic.setActiveAmount(playerData.trafficActive)
    end
  end
  if updateAmount then
    playerData.maxTrafficAmount = gameplay_traffic.getTrafficAmount(true)
    playerData.maxParkingAmount = gameplay_parking.getParkingAmount(true)
  end
end

local function onTrafficStopped()
  if playerData.traffic then
    table.clear(playerData.traffic)
  end

  -- Prevent re-spawning via multiSpawn if vehicle rotation pool is managing the fleet
  if gameplay_vehicleRotationPool and gameplay_vehicleRotationPool.getTotalCount() > 0 then
    return
  end
  
  -- A helper may stop the old batch as part of its own asynchronous setup.
  -- Do not interpret that intermediate event as a request for another batch.
  if M.ensureTraffic and not trafficSetupInProgress then
    setupTraffic(true)
  end
end

local function calculateSuspectPursuitFine(pursuitData)
  local violations = math.max(1, tonumber(pursuitData.uniqueOffensesCount) or tonumber(pursuitData.offensesCount) or 1)
  local score = math.max(0, tonumber(pursuitData.score) or 0)
  local mode = math.max(1, tonumber(pursuitData.mode) or 1)
  local globalIndex = 1
  if career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex then
    globalIndex = career_modules_globalEconomy.getGlobalIndex() or 1
  end
  local sectionMult = 1
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    sectionMult = career_economyAdjuster.getSectionMultiplier("police") or 1
  end
  local base = violations * 100 + score * 0.5 + mode * 75
  local fine = math.floor(base * globalIndex * sectionMult)
  return math.max(150, math.min(fine, 750000))
end

local function onPursuitAction(vehId, action, data)
  if gameplay_taxi and gameplay_taxi.isTaxiRideActive and gameplay_taxi.isTaxiRideActive() then
    return
  end
  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end
  if gameplay_missions_missionManager.getForegroundMissionId() or career_modules_tutorial.isActive() then
    return
  end

  if action == "start" then
    gameplay_parking.disableTracking(vehId)
    log("I", "career", "Police pursuing player, now deactivating recovery prompt buttons")
  elseif action == "reset" or action == "evade" then
    if not gameplay_walk.isWalking() then
      gameplay_parking.enableTracking(vehId)
    end
    log("I", "career", "Pursuit ended, now activating recovery prompt buttons")
  elseif action == "arrest" then
    if getPlayerIsCop() then
      return
    end
    local fine = calculateSuspectPursuitFine(data)
    career_modules_payment.pay({money = {amount = fine, canBeNegative = true}}, {label = "Police fine", tags = {"fine"}})
    local mode = tonumber(data.mode) or 1
    local prefix = mode == 1 and "Citation fine" or "Arrest fine"
    ui_message(
      string.format("%s: $%d (%d violations, pursuit score %.0f)", prefix, fine,
        math.max(1, tonumber(data.uniqueOffensesCount) or tonumber(data.offensesCount) or 1),
        math.max(0, tonumber(data.score) or 0)),
      5, "careerPursuit")
    local invId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
    if invId then
      if mode == 1 then
        career_modules_inventory.addTicket(invId)
      else
        career_modules_inventory.addArrest(invId)
      end
    end
  end
end

local function onTrafficOrParkingReady()
  -- setupTrafficHelper is finished only after both asynchronous groups are
  -- ready. onTrafficStarted can arrive earlier while parking is still spawning.
  trafficSetupInProgress = false
  if not career_modules_tutorial.isActive() then
    local parkingAmount = playerData.desiredParkingAmount
    if not parkingAmount then
      _, parkingAmount = getFallbackTrafficAmounts()
    end
    gameplay_parking.setActiveAmount(parkingAmount)
  end
  if core_gamestate.getLoadingStatus('careerVehicles') then
    log("I", "career", "Traffic is now ready for career mode")
    core_gamestate.requestExitLoadingScreen('careerVehicles')
    if freeroam_specialTriggers then
      for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
        freeroam_specialTriggers.setTriggerActive(k, false, true)
      end
    end
  end
  ensureVanillaTaxiReady()
  if career_modules_tutorial.isActive() then
    log("I", "career", "Stashing traffic and parked vehicles for tutorial")
    cacheTutorialTrafficRestoreAmounts()
    gameplay_traffic.scatterTraffic()
    gameplay_traffic.setActiveAmount(0)
    gameplay_parking.scatterParkedCars()
    gameplay_parking.setActiveAmount(0)
  end
end

local function onVehicleSwitched(oldId, newId)
  if be:getPlayerVehicleID(0) ~= newId then
    return
  end
  if not career_career.tutorialEnabled and not gameplay_missions_missionManager.getForegroundMissionId() then
    setPlayerData(newId, oldId)
    setTrafficVars()
    local playerIsCop = getPlayerIsCop({switchOldId = oldId})
    if playerIsCop then
      local trafficVehicle = gameplay_traffic.getTrafficData()[newId]
      if trafficVehicle then
        trafficVehicle.ignorePolice = true
        if trafficVehicle.pursuit and trafficVehicle.pursuit.mode ~= 0 then
          gameplay_police.setPursuitMode(0, newId)
        elseif trafficVehicle.pursuit then
          trafficVehicle.pursuit.mode = 0
          trafficVehicle.pursuit.score = 0
        end
      end
      -- Drop any AI units that were still locked onto this player-cop.
      local policeUnits = gameplay_police.getPoliceVehicles and gameplay_police.getPoliceVehicles()
      if policeUnits then
        for pid, pVeh in pairs(policeUnits) do
          if pid ~= newId and pVeh.role and pVeh.role.targetId == newId then
            pVeh.role:resetAction()
          end
        end
      end
      local policeDisabled, disabledReason = career_modules_enforcement.isPoliceDisabled()
      if policeDisabled then
        ui_message("Police service disabled: " .. disabledReason, 8, "Police", "warning")
      else
        ui_message("You are now a cop", 5, "Police", "info")
      end
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if M.preStart and freeroam_specialTriggers and playerData.traffic then
    if not playerData.preStartTicks then
      playerData.preStartTicks = 6
    end
    playerData.preStartTicks = playerData.preStartTicks - 1
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      if not v.vehIds[be:getPlayerVehicleID(0)] then
        if playerData.preStartTicks == 3 then
          freeroam_specialTriggers.setTriggerActive(k, true, true)
        elseif playerData.preStartTicks == 0 then
          freeroam_specialTriggers.setTriggerActive(k, false, true)
          M.preStart = false
        end
      end
    end
    if playerData.preStartTicks == 0 then
      playerData.preStartTicks = nil
    end
  end

  if not playerPursuitActive() then
    return
  end

  if not playerData.pursuitStuckTimer then
    playerData.pursuitStuckTimer = 0
  end
  if (playerData.traffic.speed < 3 and playerData.traffic.pursuit.timers.arrest == 0 and
    playerData.traffic.pursuit.timers.evade == 0) then
    playerData.pursuitStuckTimer = playerData.pursuitStuckTimer + dtSim
    if playerData.pursuitStuckTimer >= 10 then
      log("I", "career", "Ending pursuit early due to stalemate")
      gameplay_police.evadeVehicle(be:getPlayerVehicleID(0), true)
      playerData.pursuitStuckTimer = 0
    end
  else
    playerData.pursuitStuckTimer = 0
  end
end

local function onCareerActive(active)
  if not active then
    trafficSetupInProgress = false
  end
  if active then
    M.ensureTraffic = true
    if playerData.maxTrafficAmount == 0 then
      setupTraffic()
    end
  end
  if core_gamestate.loading() and freeroam_specialTriggers then
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      freeroam_specialTriggers.setTriggerActive(k, true, true)
    end
  end
end

-- Career activate handoffs (map switch, exit→reload, deferred profile load) all
-- disable freeroam traffic and expect playerDriving to spawn it. Stock .39 only
-- spawns when maxTrafficAmount == 0; force respawn on every module activate.
local function onCareerModulesActivated(alreadyInLevel)
  M.ensureTraffic = true
  setupTraffic(true)
end

local function onClientStartMission()
  setupTraffic()
end

local function onWorldReadyState(state)
  if state == 2 and career_career.isActive() then
    setupTraffic()
  end
end

local function buildCamPath(targetPos, endDir)
  local path = {
    looped = false,
    manualFov = false
  }
  local startPos = core_camera.getPosition() + vec3(0, 0, 30)

  local m1 = {
    fov = 30,
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = startPos,
    rot = quatFromDir(targetPos - startPos),
    time = 0,
    trackPosition = false
  }
  local m2 = {
    fov = 30,
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = startPos,
    rot = quatFromDir(targetPos - startPos),
    time = 0.5,
    trackPosition = false
  }
  local m3 = {
    fov = core_camera.getFovDeg(),
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = core_camera.getPosition(),
    rot = endDir and quatFromDir(endDir) or core_camera.getQuat(),
    time = 5.5,
    trackPosition = false
  }
  path.markers = {m1, m2, m3}

  return path
end

local function showPosition(pos)
  local camDir = pos - getPlayerVehicle(0):getPosition()
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(camDir)
  end

  local camDirLength = camDir:length()
  local rayDist = castRayStatic(getPlayerVehicle(0):getPosition(), camDir, camDirLength)

  if rayDist < camDirLength then
    local camPath = buildCamPath(pos, camDir)
    local initData = {}
    initData.finishedPath = function(this)
      core_camera.setVehicleCameraByIndexOffset(0, 1)
    end
    core_paths.playPath(camPath, 0, initData)
  end
end

M.getPlayerData = getPlayerData
M.retrieveFavoriteVehicle = retrieveFavoriteVehicle
M.getFavoriteVehicleRetrievalPrice = getFavoriteVehicleRetrievalPrice
M.playerPursuitActive = playerPursuitActive
M.resetPlayerState = resetPlayerState
M.restoreTrafficAfterMission = function()
  M.ensureTraffic = true
  setupTraffic(true)
end
M.setTrafficForTutorial = setTrafficForTutorial
M.setTrafficAfterTutorial = setTrafficAfterTutorial
M.restoreTrafficAfterTutorialPhase = restoreTrafficAfterTutorialPhase
M.teleportToGarage = teleportToGarage
M.showPosition = showPosition
M.getPlayerIsCop = getPlayerIsCop
M.ensureVanillaTaxiReady = ensureVanillaTaxiReady

M.onTrafficOrParkingReady = onTrafficOrParkingReady
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onPursuitAction = onPursuitAction
M.onVehicleParkingStatus = onVehicleParkingStatus
M.onVehicleSwitched = onVehicleSwitched
M.onCareerActive = onCareerActive
M.onCareerModulesActivated = onCareerModulesActivated
M.onClientStartMission = onClientStartMission
M.onWorldReadyState = onWorldReadyState
M.onSettingsChanged = onSettingsChanged
M.onUpdate = onUpdate

return M
