-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {}

local didTestDrive

local leaveSaleDist = 25
local vehToSalePosDist = 10
local arriveToVehInspectionDist = 20
local leaveSaleTether
local testDriveTime = 60

local testDriveInfo
local testDriveVehInfo
local timeLeftToInspectVehicle = 0
local hasPlayerArrivedToVehInspection = false
local checkTestDriveVehMovedFlag = false
local purchaseTether
local inspectionRouteTarget
local inspectionRouteToken

-- Navigation is shared by every career activity. Only clear the inspection
-- route if it is still the active route; the player may have selected a new
-- destination while the inspection vehicle is being cleaned up asynchronously.
local function copyRouteTarget(target)
  if not target then return nil end
  local ok, result = pcall(function()
    return vec3(target.x, target.y, target.z)
  end)
  return ok and result or nil
end

local function setInspectionRoute(target)
  local routeTarget = copyRouteTarget(target)
  if not routeTarget or not core_groundMarkers or not core_groundMarkers.setPath then
    return false
  end
  if overhaul_groundMarkerOwnership and overhaul_groundMarkerOwnership.install then
    overhaul_groundMarkerOwnership.install()
  end
  inspectionRouteToken = core_groundMarkers.setPath(routeTarget)
  inspectionRouteTarget = routeTarget
  return true
end

local function clearInspectionRoute()
  local ownedTarget = inspectionRouteTarget
  local ownedToken = inspectionRouteToken
  inspectionRouteTarget = nil
  inspectionRouteToken = nil
  if not ownedTarget or not core_groundMarkers then return false end

  local currentTarget = core_groundMarkers.getTargetPos and core_groundMarkers.getTargetPos() or nil
  if not currentTarget then return false end

  local ok, distance = pcall(function()
    return (currentTarget - ownedTarget):length()
  end)
  if not ok or distance > 1 then return false end

  if core_groundMarkers.clearOwnedPath then
    return core_groundMarkers.clearOwnedPath(ownedToken)
  end
  core_groundMarkers.setPath(nil)
  return true
end

local function setTimeToInspectVehicle()
  local pathLength = core_groundMarkers.getPathLength()
  local timeToInspectVehicle = pathLength / 5
  timeLeftToInspectVehicle = math.ceil(timeToInspectVehicle / 60) * 60
end

local function addVehTetherToSalePos()
  checkTestDriveVehMovedFlag = true
end

local function removeVehTetherToSalePos()
  checkTestDriveVehMovedFlag = false
end

local function addSaleTether()
  leaveSaleTether = career_modules_tether.startVehicleTether(testDriveVehInfo.vehId, leaveSaleDist, false, function()
    M.leaveSaleCallback("flagForDeletion", true, true)
  end)
end

local function removeSaleTether()
  if leaveSaleTether then
    career_modules_tether.removeTether(leaveSaleTether)
    leaveSaleTether = nil
  end
end

local function resetInspectionData()
  local inspectedVehId = testDriveVehInfo and testDriveVehInfo.vehId or nil
  didTestDrive = false
  timeLeftToInspectVehicle = 0
  hasPlayerArrivedToVehInspection = false
  testDriveInfo = nil
  testDriveVehInfo = nil

  if inspectedVehId and career_modules_tireSystem and career_modules_tireSystem.unregisterInspectionVehicle then
    career_modules_tireSystem.unregisterInspectionVehicle(inspectedVehId)
  end
  if inspectedVehId and vehicleMaintenance and vehicleMaintenance.unregisterInspectionVehicle then
    vehicleMaintenance.unregisterInspectionVehicle(inspectedVehId)
  end

  removeSaleTether()
  removeVehTetherToSalePos()

  clearInspectionRoute()

  gameplay_rawPois.clear()
  -- Walking mode only dismisses the prompt on an "out" transition; deleting the
  -- inspect POI in-place leaves Purchase Vehicle stuck without a forced close.
  if gameplay_markerInteraction and gameplay_markerInteraction.closeViewDetailPrompt then
    gameplay_markerInteraction.closeViewDetailPrompt(true)
  end
end

local function spawnVehicle(shopId)
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  core_vehicleBridge.executeAction(newVeh,'setIgnitionLevel', 0)
  core_vehicleBridge.executeAction(newVeh, 'setFreeze', true)
  local conditionMileage = vehicleInfo.wearMileage or vehicleInfo.Mileage
  newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", conditionMileage,
    career_modules_vehicleShopping.getVisualValueFromMileage(conditionMileage)))
  if career_modules_tireSystem and career_modules_tireSystem.registerInspectionVehicle then
    career_modules_tireSystem.registerInspectionVehicle(newVeh:getID(), vehicleInfo)
  end
  if vehicleMaintenance and vehicleMaintenance.registerInspectionVehicle then
    vehicleMaintenance.registerInspectionVehicle(newVeh:getID(), vehicleInfo)
  end
  return newVeh
end

local function showVehicle(vehicleInfo)
  local vehObj
  if vehicleInfo then
    vehObj = spawnVehicle(vehicleInfo.shopId)
    testDriveVehInfo = {shopId = vehicleInfo.shopId, vehId = vehObj:getID(), name = vehicleInfo.Brand .. " " .. vehicleInfo.Name, value = vehicleInfo.Value}
  end

  return vehObj
end

local function defineTestDriveParameters(vehicleInfo, parkingSpot, doesThePlayerHaveToDriveThere)
  if vehicleInfo.sellerId == "private" then
    testDriveInfo = {
      timeLimit = testDriveTime,
      abandonFees = 0
    }
  else
    local dealership = freeroam_facilities.getDealership(vehicleInfo.sellerId)
    local route
    if dealership.testDrive then
      if dealership.testDrive.parkingSpotRoutes then
        for i, parkingSpotRoute in pairs(dealership.testDrive.parkingSpotRoutes) do
          if parkingSpotRoute.parkingSpotName == parkingSpot.name then
            route = parkingSpotRoute.route
          end
        end
      end
      testDriveInfo = {
        timeLimit = testDriveTime,
        areaLimit = dealership.testDrive.areaLimit,
        abandonFees = dealership.testDrive.abandonFees or 0,
        route = route,
        dealershipName = _tr(dealership.name),
        dealershipPreview = dealership.preview
      }
      if dealership.testDrive.enableEndParkingSpot then
        testDriveInfo.endParkingSpot = parkingSpot
      end
    else
      testDriveInfo = {}
      log('W','testDrive', "Dealership : '" .. dealership.name .. "' doesn't have any 'testDriveRules' which shouldn't be possible. At least one constraint has to be given")
    end
  end

  testDriveInfo.vehicleInfo = vehicleInfo
  testDriveInfo.startParkingSpot = parkingSpot
  testDriveInfo.doesThePlayerHaveToDriveThere = doesThePlayerHaveToDriveThere
end

local function turnTowardsPos(pos)
  core_vehicleBridge.requestValue(getPlayerVehicle(0), function()
    gameplay_walk.setRot(pos - getPlayerVehicle(0):getPosition())
  end , 'ping')
end

local function leaveSaleCallback(despawnPreviousVehMode, freezePreviousVeh, checkDamage, defaultLeaveMessage)
  if despawnPreviousVehMode == nil then
    despawnPreviousVehMode = "dontDespawn"
  end
  if freezePreviousVeh == nil then
    freezePreviousVeh = true
  end
  if checkDamage == nil then
    checkDamage = true
  end
  if defaultLeaveMessage == nil then
    defaultLeaveMessage = "You have left the sale."
  end
  if not testDriveVehInfo then return end

  local vehId = testDriveVehInfo.vehId

  -- Flagged sale vehicles stay in the world until the deletion service can
  -- remove them out of view. Stop walk mode from offering that stale vehicle
  -- during the interim (and during the short async teardown for despawns).
  if despawnPreviousVehMode ~= "dontDespawn" then
    local veh = getObjectByID(vehId)
    if veh then
      veh.playerUsable = false
    end
  end

  -- Dismiss immediately; resetInspectionData also closes, but that runs after the job sleep.
  if gameplay_markerInteraction and gameplay_markerInteraction.closeViewDetailPrompt then
    gameplay_markerInteraction.closeViewDetailPrompt(true)
  end

  core_jobsystem.create(function(job)
    job.sleep(0.1)
    if career_modules_testDrive.isActive() then
      career_modules_testDrive.abandonTestDrive()
    else
      if not dontShowLeaveSaleMessage then
        ui_message(defaultLeaveMessage, '4', 'testDriveAbandoned')
      end
    end

    if didTestDrive and checkDamage then
      local damageCheckDone = false
      career_modules_insurance_insurance.handleTestDriveEndDamage(vehId, function()
        damageCheckDone = true
      end)
      local timeout = 5
      while not damageCheckDone and timeout > 0 do
        job.sleep(0.05)
        timeout = timeout - 0.05
      end
    end

    if despawnPreviousVehMode == "despawn" then
      local veh = getObjectByID(vehId)
      if veh then
        veh:delete()
      end
    else
      if despawnPreviousVehMode == "flagForDeletion" then
        career_modules_vehicleDeletionService.flagForDeletion(vehId)
      end
      local veh = getObjectByID(vehId)
      if veh then
        core_vehicleBridge.executeAction(veh, 'setFreeze', freezePreviousVeh)
      end
    end

    resetInspectionData()
  end,1)
end

local function startInspection(vehicleInfo, teleportToVehicle)
  if not vehicleInfo then return end
  if career_modules_vehicleShopping and career_modules_vehicleShopping.isOnlineSellerId
      and career_modules_vehicleShopping.isOnlineSellerId(vehicleInfo.sellerId) then
    return
  end
  core_jobsystem.create(function(job)
    if testDriveInfo then
      leaveSaleCallback("despawn")
      job.sleep(0.35)
    end

    local vehToInspect = showVehicle(vehicleInfo)
    if not vehToInspect then return end

    local parkingSpot
    local doesThePlayerHaveToDriveThere = false

    if vehicleInfo.sellerId == "private" then
      parkingSpot = gameplay_parking.getParkingSpots().byName[vehicleInfo.parkingSpotName]
      if not teleportToVehicle then
        doesThePlayerHaveToDriveThere = true
      end
    else
      local dealership = freeroam_facilities.getDealership(vehicleInfo.sellerId)
      local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
      parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehToInspect:getID(), parkingSpots)

      if vehicleInfo.sellerId == career_modules_vehicleShopping.getCurrentSellerId() then
        gameplay_walk.setWalkingMode(true)
        turnTowardsPos(parkingSpot.pos)
      elseif not teleportToVehicle then
        doesThePlayerHaveToDriveThere = true
      end
    end

    local hasVehicles, vehicleIds = parkingSpot:hasAnyVehicles()
    if hasVehicles then
      for _, vId in ipairs(vehicleIds) do
        gameplay_traffic.forceTeleport(vId)
      end
    end

    parkingSpot:moveResetVehicleTo(vehToInspect:getID(), nil, nil, nil, nil, true)

    if teleportToVehicle then
      career_modules_quickTravel.quickTravelToPos(parkingSpot.pos, true)
    else
      if doesThePlayerHaveToDriveThere then
        setInspectionRoute(parkingSpot.pos)
        setTimeToInspectVehicle()
      end
    end

    defineTestDriveParameters(vehicleInfo, parkingSpot, doesThePlayerHaveToDriveThere)

    if not doesThePlayerHaveToDriveThere then
      addSaleTether()
      addVehTetherToSalePos()
    end
    gameplay_rawPois.clear()
  end,1)
end

local function buySpawnedVehicle(buyVehicleOptions)
  local ok = career_modules_vehicleShopping.buySpawnedVehicle(buyVehicleOptions)
  if ok then
    leaveSaleCallback("dontDespawn", false, false, "You purchased the vehicle.")
  end
  return ok
end

local function playerDidntArriveOnTime()
  leaveSaleCallback("flagForDeletion", true, false, "The seller has waited for too long. He has canceled the sale.")
end

local function updateTimeLeftToInspectVehicle(dtSim)
  timeLeftToInspectVehicle = timeLeftToInspectVehicle - dtSim
  if timeLeftToInspectVehicle <= 0 then
    playerDidntArriveOnTime()
  end
end

local tempVecDir = vec3()
local function checkIfPlayerHasArrivedToVehInspection(playerVehObj, vehObj)
  local distanceToVeh = vehObj:getPosition():distance(playerVehObj:getPosition())
  if distanceToVeh < arriveToVehInspectionDist then
    tempVecDir:setSub2(vehObj:getPosition(), playerVehObj:getPosition())
    local vehDist = castRayStatic(playerVehObj:getPosition(), tempVecDir, arriveToVehInspectionDist)
    if vehDist >= distanceToVeh then
      hasPlayerArrivedToVehInspection = true
      addSaleTether()
      addVehTetherToSalePos()
      -- Keep navigation until the normal ground-marker arrival distance is
      -- reached. Clearing here at 20 m made the waypoint appear to vanish
      -- early, often during the inspection hitch.
    end
  end
end

local function checkTestDriveVehMoved(vehObj)
  if checkTestDriveVehMovedFlag then
    local distanceToVeh = vehObj:getPosition():distance(testDriveInfo.startParkingSpot.pos)
    if distanceToVeh > vehToSalePosDist then
      M.leaveSaleCallback("flagForDeletion", false, false, "The seller's vehicle has been moved. The sale has been cancelled.")
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not testDriveVehInfo then return end

  local vehObj = getObjectByID(testDriveVehInfo.vehId)
  local playerVehObj = getPlayerVehicle(0)

  if testDriveInfo then
    checkTestDriveVehMoved(vehObj)
    if testDriveInfo.doesThePlayerHaveToDriveThere and not hasPlayerArrivedToVehInspection then
      updateTimeLeftToInspectVehicle(dtSim)
      checkIfPlayerHasArrivedToVehInspection(playerVehObj, vehObj)
    end
  end
end

local function onVehicleDestroyed(vehId)
  if not testDriveVehInfo then return end
  if vehId == testDriveVehInfo.vehId then
    resetInspectionData()
  end
end

local function onTestDriveStarted()
  didTestDrive = true
  removeSaleTether()
  removeVehTetherToSalePos()
end

local function onAnyMissionChanged(status, id)
  if not (career_career and career_career.isActive()) then return end
  if status == "started" then
    leaveSaleCallback("despawn")
  end
end

local function onDeliveryModeStarted()
  leaveSaleCallback("despawn")
end

local function startTestDrive()
  career_career.closeAllMenus()
  career_modules_testDrive.start(testDriveVehInfo.vehId, testDriveInfo)
end

local function getSpawnedVehicleInfo()
  return testDriveVehInfo
end

local function repairVehicle()
  core_jobsystem.create(function(job)
    ui_fadeScreen.start(1)
    job.sleep(1.5)
    career_modules_insurance_insurance.payRepairIfNeededGenericVeh(vehId)
    ui_fadeScreen.stop(1)
    job.sleep(1.0)
  end)
end

local function getInspectVehiclePoi()
  if career_career.isActive() and testDriveInfo then
    local id = string.format("inspectVehicle-%s-%s-parkingEnd",testDriveInfo.dealershipName, testDriveInfo.route)
    local poi = {
      data = {
        type = "inspectVehicle",
        testDriveInfo = testDriveInfo,
      },
      id = "inspectVehicleMarker##"..id,
      markerInfo = {
        inspectVehicleMarker = {
          pos = testDriveInfo.startParkingSpot.pos,
          radius = testDriveInfo.startParkingSpot.scl:length()/2+2,
          vehicleHeight = 4,
        },
      }
    }

    if testDriveInfo.doesThePlayerHaveToDriveThere then
      poi.markerInfo.bigmapMarker = {
        pos = testDriveInfo.startParkingSpot.pos,
        icon = "mission_drift_triangle",
        name = testDriveInfo.dealershipName,
        description = "The seller awaits you at the parking spot.",
        thumbnail = testDriveInfo.dealershipPreview,
        previews = {testDriveInfo.dealershipPreview},
      }
    end

    return poi
  end
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  local inspectVehiclePoi = getInspectVehiclePoi()
  if inspectVehiclePoi then
    table.insert(elements, inspectVehiclePoi)
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "inspectVehicle" then
      local data = {
        icon = "poi_dealer_1_rect",
        heading = elem.testDriveInfo.vehicleInfo.Brand .. " - " .. elem.testDriveInfo.vehicleInfo.Name,
        preheadings = {"Purchase Vehicle"},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {
          {
            icon = "carDealer",
            keyLabel = "From : " .. elem.testDriveInfo.vehicleInfo.sellerName
          }
        }
      }

      data.buttonLabel = "See Purchase Information"
      data.buttonFun = function()
        career_modules_vehicleShopping.openPurchaseMenu("inspect", elem.testDriveInfo.vehicleInfo.shopId)
        purchaseTether = career_modules_tether.startSphereTether(getPlayerVehicle(0):getPosition(), 3, function() career_career.closeAllMenus() end)
      end
      table.insert(activityData, data)
    end
  end
end

local function getDidTestDrive()
  return didTestDrive
end

local function onPurchaseMenuClosed()
  career_modules_tether.removeTether(purchaseTether)
  purchaseTether = nil
end

local function onTestDriveAbandoned()
  leaveSaleCallback("flagForDeletion", true, true, "You have abandoned the sale.")
end

local function onTestDriveEndedAfterFade()
  if testDriveVehInfo then
    addSaleTether()
    addVehTetherToSalePos()
  else
    log("W", "inspectVehicle", "onTestDriveEndedAfterFade fired without testDriveVehInfo; sale tether will NOT be re-armed")
  end
end

M.onActivityAcceptGatherData = onActivityAcceptGatherData

M.repairVehicle = repairVehicle
M.showVehicle = showVehicle
M.buySpawnedVehicle = buySpawnedVehicle
M.startTestDrive = startTestDrive
M.startInspection = startInspection
M.getSpawnedVehicleInfo = getSpawnedVehicleInfo
M.getDidTestDrive = getDidTestDrive
M.getInspectVehiclePoi = getInspectVehiclePoi

M.onDeliveryModeStarted = onDeliveryModeStarted
M.onVehicleDestroyed = onVehicleDestroyed
M.onAnyMissionChanged = onAnyMissionChanged
M.onTestDriveStarted = onTestDriveStarted
M.onUpdate = onUpdate
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onPurchaseMenuClosed = onPurchaseMenuClosed
M.onTestDriveAbandoned = onTestDriveAbandoned
M.onTestDriveEndedAfterFade = onTestDriveEndedAfterFade

M.leaveSaleCallback = leaveSaleCallback

return M
