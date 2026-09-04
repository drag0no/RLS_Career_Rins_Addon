-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"util_stepHandler"}

local dateUtils = require('utils/dateUtils')

local walkAwayRadius = 100
local comeBackRadius = 95
local walkAwayTimeLimit = 300
local walkAwayWarningTime = 60
local loanedVehiclesInfo = {}
local LOANER_UNLOCK_MODE_ORG_REPUTATION = "orgReputation"
local LOANER_UNLOCK_MODE_SKILL_LEVEL = "skillLevel"
local DEFAULT_LOANER_UNLOCK_SKILL_LABEL = "Police Skill"
local DEFAULT_LOANER_UNLOCK_SKILL_ICON = "wigwags"
local DEFAULT_LOANER_UNLOCK_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"}

local function getBranchLevelByPathIds(pathIds)
  if not career_branches or not career_branches.getBranchLevel then
    return 0
  end

  for _, skillPathId in ipairs(pathIds or {}) do
    local branchLevel = career_branches.getBranchLevel(skillPathId)
    local level = tonumber(branchLevel)
    if level then
      return math.max(0, math.floor(level))
    end
  end

  return 0
end

local function getLoanerUnlockMode(organization)
  local mode = organization and organization.loanerUnlockMode
  if mode == LOANER_UNLOCK_MODE_SKILL_LEVEL then
    return LOANER_UNLOCK_MODE_SKILL_LEVEL
  end
  return LOANER_UNLOCK_MODE_ORG_REPUTATION
end

local function getLoanerUnlockSkillPathIds(organization)
  local pathIds = organization and organization.loanerUnlockSkillPathIds
  if type(pathIds) == "table" and #pathIds > 0 then
    return pathIds
  end

  local pathId = organization and organization.loanerUnlockSkillPathId
  if type(pathId) == "string" and pathId ~= "" then
    return {pathId}
  end

  return DEFAULT_LOANER_UNLOCK_SKILL_PATH_IDS
end

local function getLoanerUnlockSkillLevel(organization)
  return getBranchLevelByPathIds(getLoanerUnlockSkillPathIds(organization))
end

local function getLoanerUnlockSkillDisplayData(organization)
  local label = organization and organization.loanerUnlockSkillLabel or DEFAULT_LOANER_UNLOCK_SKILL_LABEL
  local icon = organization and organization.loanerUnlockSkillIcon or DEFAULT_LOANER_UNLOCK_SKILL_ICON
  return label, icon
end

local markedForSpawningLoaners = {}

local function markForSpawning(offer)
  if markedForSpawningLoaners[offer.id] then
    markedForSpawningLoaners[offer.id] = nil
  else
    markedForSpawningLoaners[offer.id] = offer
  end
end
M.markForSpawning = markForSpawning

local function unmarkAllForSpawning()
  markedForSpawningLoaners = {}
end
M.unmarkAllForSpawning = unmarkAllForSpawning

local vehicleAdded = false
local function onVehicleAdded(id)
  vehicleAdded = true
end

local function getConfigInfo(model, config)
  if not model or not config then return nil end
  local configInfo = core_vehicles.getConfig(model, config)
  if configInfo and configInfo.infoFilename then
    local rawInfo = jsonReadFile(configInfo.infoFilename)
    configInfo.loanerName = rawInfo and rawInfo.loanerName or nil
  end
  return configInfo
end

local function getInventoryConfigInfo(vehicleInfo)
  if not vehicleInfo then return nil end
  local config = vehicleInfo.config
  local configFilename = nil
  if type(config) == "table" and type(config.partConfigFilename) == "string" then
    local _, filename = path.splitWithoutExt(config.partConfigFilename)
    configFilename = filename
  elseif type(config) == "string" then
    local _, filename = path.splitWithoutExt(config)
    configFilename = filename or config
  end
  return getConfigInfo(vehicleInfo.model, configFilename)
end

local function isTrailerVehicle(configInfo, model)
  local aggregates = configInfo and configInfo.aggregates
  if aggregates and aggregates.Type and aggregates.Type.Trailer then
    return true
  end
  local modelInfo = model and core_vehicles.getModel(model)
  local modelData = modelInfo and (modelInfo.model or modelInfo)
  return modelData and modelData.Type == "Trailer" or false
end

local function getOrganizationReputationLevel(organization, level)
  if not organization or type(organization.reputationLevels) ~= "table" then return nil end
  local reputationLevel = level
  if reputationLevel == nil and organization.reputation then
    reputationLevel = organization.reputation.level
  end
  return organization.reputationLevels[(tonumber(reputationLevel) or 0) + 2]
end

local function flattenXY(dir, fallback)
  local flat = vec3(dir.x, dir.y, 0)
  if flat:squaredLength() > 1e-6 then
    flat:normalize()
    return flat
  end
  return fallback or vec3(0, -1, 0)
end

local function loanerNudgeBlockedByVehicle(pos, ignoreVehId, radius)
  local r2 = (radius or 3.5) * (radius or 3.5)
  local vehicles = getAllVehicles and getAllVehicles() or {}
  for _, veh in ipairs(vehicles) do
    local id = veh.getID and veh:getID() or (veh.getId and veh:getId())
    if id and id ~= ignoreVehId then
      local p = veh:getPosition()
      local dx, dy = p.x - pos.x, p.y - pos.y
      if dx * dx + dy * dy < r2 then
        return true
      end
    end
  end
  return false
end

local LOANER_NO_SPACE_MSG = "There are no parking spots for loaner vehicles of this type."

-- Same-deck only. A hit far below stall Z is the stacked-geometry drop
-- (police station); that is a Z-only escape and counts as no space.
local function stallDeckOk(pos, stallZ)
  local deckHit = castRayStatic(vec3(pos.x, pos.y, stallZ + 1.5), vec3(0, 0, -1), 2.5)
  if not deckHit or deckHit >= 2.5 then
    return false
  end
  return (stallZ + 1.5 - deckHit) >= (stallZ - 0.75)
end

-- Keep stall height: reject off-pad Z, walls, and other cars.
local function loanerNudgeCandidateOk(pos, stallZ, back, right, halfL, halfW, ignoreVehId)
  if not stallDeckOk(pos, stallZ) then
    return false
  end

  local origin = vec3(pos.x, pos.y, stallZ + 0.7)
  local rays = {
    {back, halfL + 0.5},
    {back * -1, halfL + 0.5},
    {right, halfW + 0.5},
    {right * -1, halfW + 0.5},
  }
  for _, ray in ipairs(rays) do
    local dir, dist = ray[1], ray[2]
    if dir:squaredLength() > 1e-6 and castRayStatic(origin, dir, dist) < dist - 0.05 then
      return false
    end
  end

  return not loanerNudgeBlockedByVehicle(pos, ignoreVehId, math.max(halfL, halfW) + 1.6)
end

-- Use the parking spot's placement math (OOBB centering + facing correction).
-- Raw setPositionRotation on spot.pos/rot lands vehicles off-heading and half in the deck.
local function plantLoanerAt(spot, vehId, worldPos)
  if not spot or not vehId then return false end
  local offset = vec3(0, 0, 0)
  if worldPos then
    local pos = spot.pos
    local back = flattenXY(quat(spot.rot) * vec3(0, -1, 0), vec3(0, -1, 0))
    local right = flattenXY(vec3(-back.y, back.x, 0), vec3(1, 0, 0))
    local delta = worldPos - pos
    offset = vec3(right:dot(delta), back:dot(delta), 0)
  end
  spot:moveResetVehicleTo(vehId, false, false, offset, nil, false, true, true)
  return true
end

local function abortLoanerNoSpace(vehObj, offer)
  log("W", "loanerVehicles", string.format("No space for loaner %s", tostring(offer and offer.id)))
  if vehObj then
    pcall(function() vehObj:delete() end)
  end
  ui_message(LOANER_NO_SPACE_MSG, 5, "loanerNoSpace")
end

-- Empty stall: plant at the marker if that XY is on the stall deck.
-- Occupied: XY nudge at stall Z only. Never use safeTeleport's Z spiral.
-- If the only remaining move would be Z, treat it as no space.
local function teleportLoanerToSpot(vehObj, vehId, spot)
  if not vehObj or not spot or not spot.pos or not spot.rot then return false end

  local pos, rot = spot.pos, spot.rot
  local occupied, occupantIds = spot:hasAnyVehicles(vehId)
  if occupied then
    local parkedData = gameplay_parking and gameplay_parking.getParkedCarsData and gameplay_parking.getParkedCarsData() or {}
    if gameplay_parking and gameplay_parking.forceTeleport then
      for _, occupantId in ipairs(occupantIds or {}) do
        if parkedData[occupantId] then
          pcall(gameplay_parking.forceTeleport, occupantId)
        end
      end
    end
    occupied = spot:hasAnyVehicles(vehId)
  end

  local stallZ = pos.z
  if not occupied then
    if not stallDeckOk(pos, stallZ) then
      return false
    end
    plantLoanerAt(spot, vehId)
    return true
  end

  local halfL = (spot.scl and math.abs(spot.scl.y)) or 6
  local halfW = (spot.scl and math.abs(spot.scl.x)) or 3
  local back = flattenXY(quat(spot.rot) * vec3(0, -1, 0), vec3(0, -1, 0))
  local right = flattenXY(vec3(-back.y, back.x, 0), vec3(1, 0, 0))

  local candidates = {}
  local function addCandidate(offset)
    candidates[#candidates + 1] = vec3(pos.x + offset.x, pos.y + offset.y, stallZ)
  end
  for _, extra in ipairs({2.5, 5, 8}) do
    local along = halfL * 0.5 + extra
    addCandidate(back * along)
    addCandidate(back * along + right * 3)
    addCandidate(back * along + right * -3)
  end
  addCandidate(right * (halfW * 0.5 + 3.5))
  addCandidate(right * -(halfW * 0.5 + 3.5))

  for _, candidate in ipairs(candidates) do
    if loanerNudgeCandidateOk(candidate, stallZ, back, right, halfL * 0.5, halfW * 0.5, vehId) then
      plantLoanerAt(spot, vehId, candidate)
      return true
    end
  end

  return false
end

local function spawnAllOffers(onComplete)
  if not next(markedForSpawningLoaners) then
    if onComplete then onComplete() end
    return
  end
  vehicleAdded = false
  local lookAtPos
  local sequence = {
    -- fade to black
    util_stepHandler.makeStepFadeToBlack(0.4),
  }
  for id, offer in pairs(markedForSpawningLoaners) do
    -- spawn vehicle and trigger initialization
    local options = {model = offer.model, config = offer.config, autoEnterVehicle = false}
    local fac = freeroam_facilities.getFacility(offer.sourceFacility.type, offer.sourceFacility.id)
    table.insert(sequence, util_stepHandler.makeStepSpawnVehicle(options,
      function(step, vehId)
        local vehObj = scenetree.findObjectById(vehId)
        if not fac or not vehObj then
          log("E", "loanerVehicles", string.format("Could not initialize loaner %s: facility or vehicle is unavailable", tostring(offer.id)))
          return
        end
        local initOk, initErr = pcall(core_vehicleBridge.executeAction, vehObj, 'initPartConditions', {}, offer.vehMileage or 0, 1, 1)
        if not initOk then
          log("E", "loanerVehicles", string.format("Could not initialize loaner %s: %s", tostring(offer.id), tostring(initErr)))
        end
        core_vehicleBridge.requestValue(vehObj,
          function(res)
            local callbackOk, callbackErr = pcall(function()
              if not vehObj or not scenetree.findObjectById(vehId) then return end
              local modelInfo = core_vehicles.getModel(vehObj:getField('JBeam','0'))
              local vehModel = modelInfo and (modelInfo.model or modelInfo)
              local spots = (vehModel and vehModel.Type == "Trailer") and fac.loanerTrailerSpots or fac.loanerNonTrailerSpots
              local bestParkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehId, spots or {})
              if not bestParkingSpot or not teleportLoanerToSpot(vehObj, vehId, bestParkingSpot) then
                abortLoanerNoSpace(vehObj, offer)
                vehicleAdded = true
                return
              end
              offer.vehPos = vehObj:getPosition() or bestParkingSpot.pos
              lookAtPos = offer.vehPos

              local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {owned = false})
              local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
              if not vehInfo then
                log("E", "loanerVehicles", string.format("Loaner %s was spawned but could not be added to inventory", tostring(offer.id)))
                return
              end
              vehInfo.owningOrganization = fac.associatedOrganization
              vehInfo.loanType = offer.loanType
            end)
            if not callbackOk then
              log("E", "loanerVehicles", string.format("Could not finish retrieving loaner %s: %s", tostring(offer.id), tostring(callbackErr)))
            end
          end
          , 'ping')
      end
      )
    )
    table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
      function() return vehicleAdded end
    ))
  end
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
      function()
        -- markedForSpawningLoaners may already be empty: cargoScreen unmarks
        -- after spawnAllOffers returns, and we defer the sequence one tick.
        if lookAtPos then
          local playerVehicle = getPlayerVehicle(0)
          local camDir = playerVehicle and (lookAtPos - playerVehicle:getPosition()) or nil
          if camDir and gameplay_walk.isWalking() then
            gameplay_walk.setRot(camDir)
          end
        end
        markedForSpawningLoaners = {}
        return true
      end
    )
  )
  table.insert(sequence, util_stepHandler.makeStepFadeFromBlack(0.4))

  -- cargoScreen often calls this from a live stepHandler callback. Starting a
  -- nested sequence replaces taskData in-place and the outer onUpdate then
  -- skips our fade-to-black. Always start on the next job tick.
  core_jobsystem.create(function(job)
    job.sleep(0)
    util_stepHandler.startStepSequence(sequence, onComplete)
  end)
end
M.spawnAllOffers = spawnAllOffers

local function returnVehicleActual(inventoryId)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if not vehInfo then
    loanedVehiclesInfo[inventoryId] = nil
    return
  end
  if career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) and vehInfo.loanType == "work" and vehInfo.owningOrganization then
    local fine = {}
    fine[vehInfo.owningOrganization .. "Reputation"] = career_modules_reputation.getValueForEvent("returnLoanerDamaged")
    career_modules_playerAttributes.addAttributes(fine, {tags={"fine"}, label="ui.career.attributeLog.loanerDamagedReputationCost"})
    guihooks.trigger("toastrMsg", {type="warning", label = "loanReturnedDamaged", title="Loaner returned damaged", msg="Lost reputation due to returning a damaged loaned vehicle."})
  end
  career_modules_inventory.removeVehicle(inventoryId)
end

local function returnVehicle(inventoryId, callback)
  if career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
    career_modules_inventory.updatePartConditions(nil, inventoryId,
    function()
      returnVehicleActual(inventoryId)
      unmarkAllForSpawning()
      if callback then callback() end
    end)
  else
    returnVehicleActual(inventoryId)
    unmarkAllForSpawning()
    if callback then callback() end
  end
end

local function getLoanedVehicles()
  local result = {}
  for inventoryId, vehInfo in pairs(career_modules_inventory.getVehicles()) do
    if vehInfo.owningOrganization then
      local veh = deepcopy(vehInfo)
      local thumbnailOk, thumbnail = pcall(career_modules_inventory.getVehicleThumbnail, veh.id)
      veh.thumbnail = thumbnailOk and thumbnail or nil
      table.insert(result, veh)
    end
  end
  return result
end

local function getLoanedVehiclesByOrg(organizationId)
  local result = {}
  for _, vehInfo in ipairs(getLoanedVehicles()) do
    if organizationId == vehInfo.owningOrganization then
      table.insert(result, vehInfo)
    end
  end
  return result
end

local vehPos = vec3()
local playerPos = vec3()

local UPDATE_INTERVAL = 0.25
local updateAccumulator = 0
local simAccumulator = 0
local walkAwayRadiusSq = walkAwayRadius * walkAwayRadius
local comeBackRadiusSq = comeBackRadius * comeBackRadius
local expiredLoaners = {}

local function onUpdate(dtReal, dtSim, dtRaw)
  -- This watch only has to notice a 100m walk-away, so run it on a fixed cadence
  -- rather than once per rendered frame. dtSim is banked across skipped frames so
  -- the return countdown still advances at exactly the same rate as before.
  simAccumulator = simAccumulator + (tonumber(dtSim) or 0)
  updateAccumulator = updateAccumulator + (tonumber(dtReal) or 0)
  if updateAccumulator < UPDATE_INTERVAL then return end
  local simElapsed = simAccumulator
  updateAccumulator = 0
  simAccumulator = 0

  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh = playerVehId and playerVehId >= 0 and be:getObjectByID(playerVehId) or nil
  if not playerVeh then return end
  playerPos:set(playerVeh:getPosition())

  local vehicles = career_modules_inventory.getVehicles()
  local inventoryIdToVehId = career_modules_inventory.getMapInventoryIdToVehId()

  -- Walk the inventory table itself and only resolve an engine object for entries
  -- that are actually work loaners. The usual case is that the player has none,
  -- which makes this a plain field compare per owned vehicle.
  for inventoryId, vehInfo in pairs(vehicles) do
    if vehInfo.loanType == "work" and not loanedVehiclesInfo[inventoryId] then
      local vehId = inventoryIdToVehId[inventoryId]
      local vehObj = vehId and be:getObjectByID(vehId) or nil
      if vehObj then
        vehPos:set(vehObj:getPosition())
        if playerPos:squaredDistance(vehPos) > walkAwayRadiusSq then
          ui_message(string.format("You are leaving a loaned vehicle behind. After %d seconds, it will be returned to the owner.", walkAwayTimeLimit), 5, "loanedVehicleTime")
          loanedVehiclesInfo[inventoryId] = {time = walkAwayTimeLimit}
        end
      end
    end
  end

  table.clear(expiredLoaners)

  for inventoryId, loanedVehInfo in pairs(loanedVehiclesInfo) do
    if not vehicles[inventoryId] then
      loanedVehiclesInfo[inventoryId] = nil
    elseif not loanedVehInfo.returning then
      local vehId = inventoryIdToVehId[inventoryId]
      local vehObj = vehId and be:getObjectByID(vehId) or nil
      if vehObj then
        vehPos:set(vehObj:getPosition())
        if playerPos:squaredDistance(vehPos) < comeBackRadiusSq then
          loanedVehiclesInfo[inventoryId] = nil
        else
          loanedVehInfo.time = loanedVehInfo.time - simElapsed
          if loanedVehInfo.time < 0 then
            -- removeVehicle runs asynchronously behind a part condition update, so
            -- latch the entry rather than calling returnVehicle again on every tick
            -- until the inventory finally drops it.
            loanedVehInfo.returning = true
            table.insert(expiredLoaners, inventoryId)
          elseif not loanedVehInfo.warningShown and loanedVehInfo.time < walkAwayWarningTime then
            ui_message(string.format("After %d more seconds of not returning to the loaned vehicle, it will be returned to the owner.", walkAwayWarningTime), 5, "loanedVehicleTime")
            loanedVehInfo.warningShown = true
          end
        end
      end
    end
  end

  -- returnVehicle mutates the inventory, so it only runs once iteration is done.
  -- The latched entry is cleared above when the vehicle leaves the inventory.
  for _, inventoryId in ipairs(expiredLoaners) do
    returnVehicle(inventoryId)
  end
end

local function onCareerActive(active)
  table.clear(loanedVehiclesInfo)
  table.clear(expiredLoaners)
  updateAccumulator = 0
  simAccumulator = 0
end

local function getNumberOfLoanedNonTrailers(organizationId)
  local counter = 0
  for inventoryId, vehicleInfo in pairs(career_modules_inventory.getVehicles()) do
    if vehicleInfo.owningOrganization == organizationId then
      local configInfo = getInventoryConfigInfo(vehicleInfo)
      if not isTrailerVehicle(configInfo, vehicleInfo.model) then
        counter = counter + 1
      end
    end
  end
  return counter
end

local function getLoaningOrgsOfVehicle(vehId)
  local res = {}
  if not vehId or vehId < 0 then return res end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if vehInfo and vehInfo.owningOrganization then
    res[vehInfo.owningOrganization] = true
  end

  local pullingVehicleId = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer and core_trailerRespawn.getAttachedNonTrailer(vehId)
  if pullingVehicleId then
    local pullingInventoryId = career_modules_inventory.getInventoryIdFromVehicleId(pullingVehicleId)
    local pullingVehInfo = career_modules_inventory.getVehicles()[pullingInventoryId]
    if pullingVehInfo and pullingVehInfo.owningOrganization then
      res[pullingVehInfo.owningOrganization] = true
    end
  end
  return res
end

local function getNumberOfLoanersToBeSpawned()
  local numberNonTrailers, numberTrailers = 0, 0
  for id, offer in pairs(markedForSpawningLoaners) do
    local configInfo = getConfigInfo(offer.model, offer.config)
    if isTrailerVehicle(configInfo, offer.model) then
      numberTrailers = numberTrailers + 1
    else
      numberNonTrailers = numberNonTrailers + 1
    end
  end
  return numberNonTrailers, numberTrailers
end

local function getRentalMileage(rentalVehicleInfo, organization)
  if rentalVehicleInfo.mileages then
    local reputationLevel = organization and organization.reputation and organization.reputation.level or 0
    if rentalVehicleInfo.mileages[tostring(reputationLevel)] then
      return rentalVehicleInfo.mileages[tostring(reputationLevel)]
    else
      return select(2, next(rentalVehicleInfo.mileages))
    end
  end
  if rentalVehicleInfo.mileage then
    return rentalVehicleInfo.mileage
  end
  return 0
end

local function formatSpawnedLoanersForUi()
  local result = {}
  for _, vehInfo in ipairs(getLoanedVehicles()) do
    local veh = deepcopy(vehInfo)
    local organization = freeroam_organizations.getOrganization(veh.owningOrganization)
    local configInfo = getInventoryConfigInfo(vehInfo)
    local reputationLevel = getOrganizationReputationLevel(organization)

    veh.loanerCut = reputationLevel and reputationLevel.loanerCut or 0
    local nameOk, translatedName = pcall(career_modules_inventory.getVehicleNiceNameTranslated, veh.id)
    veh.name = configInfo and configInfo.loanerName or (nameOk and translatedName or veh.niceName)
    if type(veh.name) ~= "string" or veh.name == "" then
      local offerName = configInfo and configInfo.Name
      if core_locales and core_locales.translateWithOrWithoutContext then
        offerName = core_locales.translateWithOrWithoutContext(offerName)
      end
      veh.name = (type(offerName) == "string" and offerName ~= "") and offerName or (veh.model or "Loaner")
    end
    local mileageOk, mileage = pcall(career_modules_valueCalculator.getVehicleMileageById, veh.id)
    veh.vehMileage = mileageOk and mileage or 0
    veh.organizationName = organization and organization.name or veh.owningOrganization or "Unknown organization"
    veh.vehOfferType = isTrailerVehicle(configInfo, vehInfo.model) and "trailer" or "vehicle"
    veh.enabled = true
    veh.isSpawnedLoaner = true

    if configInfo and configInfo.capacity then
      veh.capacity = {}
      for _, cap in ipairs(configInfo.capacity) do
        if cap.type == "fluid" then
          table.insert(veh.capacity, {
            icon = career_modules_delivery_parcelMods.getModifierIcon(cap.type),
            labelShort = string.format("%dL", cap.amount),
            labelLong = string.format("Fluids: %dL", cap.amount),
          })
        end
      end
    end

    table.insert(result, veh)
  end
  return result
end

local function formatLoanerOfferForUi(facility)
  local organizationId = facility.associatedOrganization
  local organization = freeroam_organizations.getOrganization(organizationId)
  if not organization then return nil end
  local ret = {}
  local loanerUnlockMode = getLoanerUnlockMode(organization)
  local usesSkillUnlocks = loanerUnlockMode == LOANER_UNLOCK_MODE_SKILL_LEVEL
  local orgSkillLevel = usesSkillUnlocks and getLoanerUnlockSkillLevel(organization) or 0
  local skillLabel, skillIcon = getLoanerUnlockSkillDisplayData(organization)

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  local saveData = (savePath and jsonReadFile(savePath .. "/info.json")) or {}
  local secondsSinceSaveFileCreation = saveData.creationDate and dateUtils.timeSince(saveData.creationDate) or 0

  local loanableVehicleEntries = {}
  -- A delivery facility may define a purpose-built fleet without changing every
  -- other facility that shares its organization. Existing organization fleets
  -- remain the fallback for facilities that do not opt in.
  for idx, rentalVehicleInfo in ipairs(facility.loanableVehicles or organization.loanableVehicles or {}) do
    table.insert(loanableVehicleEntries, {idx = idx, vehicle = rentalVehicleInfo})
  end

  if usesSkillUnlocks then
    table.sort(loanableVehicleEntries, function(a, b)
      local levelA = tonumber(a.vehicle.requiredSkillLevel or a.vehicle.requiredPoliceLevel) or 0
      local levelB = tonumber(b.vehicle.requiredSkillLevel or b.vehicle.requiredPoliceLevel) or 0
      if levelA ~= levelB then
        return levelA > levelB
      end
      return a.idx < b.idx
    end)
  end

  for displayIdx, entry in ipairs(loanableVehicleEntries) do
    local rentalVehicleInfo = entry.vehicle
    local configInfo = getConfigInfo(rentalVehicleInfo.model, rentalVehicleInfo.config)
    local hasFreeParkingSpot = false
    local isTrailer = isTrailerVehicle(configInfo, rentalVehicleInfo.model)
    local spots = (isTrailer and facility.loanerTrailerSpots or facility.loanerNonTrailerSpots) or {}

    local numberNonTrailersToBeSpawned, numberTrailersToBeSpawned = getNumberOfLoanersToBeSpawned()
    local counterSpawnedVehiclesOfSameType = isTrailer and numberTrailersToBeSpawned or numberNonTrailersToBeSpawned

    -- Occupied stalls still count in the menu. Spawn tries an XY nudge at
    -- stall height; if that cannot resolve, it aborts as no space.
    for _ in ipairs(spots) do
      counterSpawnedVehiclesOfSameType = counterSpawnedVehiclesOfSameType - 1
      if counterSpawnedVehiclesOfSameType < 0 then
        hasFreeParkingSpot = true
        break
      end
    end

    local disableReason, unlockInfo
    local enabled = true
    if not hasFreeParkingSpot then
      enabled = false
      disableReason = {
        type = "noSpace",
        label  = "There are no parking spots for loaner vehicles of this type.",
      }
    end

    if not isTrailer and (getNumberOfLoanedNonTrailers(organizationId) + numberNonTrailersToBeSpawned) > 0 then
      enabled = false
      disableReason = {
        type = "limit",
        label = "You already have a loaned vehicle of that type from this organization.",
      }
    end

    local requiredSkillLevel = tonumber(rentalVehicleInfo.requiredSkillLevel or rentalVehicleInfo.requiredPoliceLevel) or 0
    local requiredReputationLvl = tonumber(rentalVehicleInfo.reputationLvl)
    local failsSkillGate = usesSkillUnlocks and requiredSkillLevel > 0 and orgSkillLevel < requiredSkillLevel
    local failsRepGate = requiredReputationLvl ~= nil and requiredReputationLvl > organization.reputation.level
    if usesSkillUnlocks and failsSkillGate then
      enabled = false
      disableReason = {
        type = "locked",
        icon = skillIcon,
        level = requiredSkillLevel,
        label = string.format("Requires %s level %d", skillLabel, requiredSkillLevel)
      }
      unlockInfo = {
        type = "minLevel",
        icon = skillIcon,
        longLabel = string.format("Requires %s level %d", skillLabel, requiredSkillLevel),
        shortLabel = string.format("lvl %d", requiredSkillLevel)
      }
    elseif failsRepGate then
      enabled = false
      disableReason = {
        type = "locked", icon = "peopleOutline", level = rentalVehicleInfo.reputationLvl,
        label = string.format("Requires Reputation '%s' with %s", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, organization.name)
      }
      unlockInfo = {
        type = "minLevel", icon = "peopleOutline", longLabel = string.format("Requires Reputation '%s' with %s", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, organization.name), shortLabel = string.format("%s (lvl %d)", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, rentalVehicleInfo.reputationLvl)
      }
    end

    local id = string.format("%s-%04d", organizationId, displayIdx)

    --ignore enable state when already bringin out this loaner
    if markedForSpawningLoaners[id] then
      enabled = true
      disableReason = nil
    end
    local offerName = configInfo and (configInfo.loanerName or configInfo.Name)
    if core_locales and core_locales.translateWithOrWithoutContext then
      offerName = core_locales.translateWithOrWithoutContext(offerName)
    end
    if type(offerName) ~= "string" or offerName == "" then
      offerName = rentalVehicleInfo.config or rentalVehicleInfo.model or "Loaner"
    end
    local item = {
      id = id,
      model = rentalVehicleInfo.model,
      config = rentalVehicleInfo.config,
      loanerCut = (getOrganizationReputationLevel(organization) or {}).loanerCut or 0,
      vehOfferType = isTrailer and "trailer" or "vehicle",
      name = offerName,
      vehMileage = getRentalMileage(rentalVehicleInfo, organization) + (5.8 + 5.8 * ((math.random() * 0.2) - 0.1)) * secondsSinceSaveFileCreation, -- this roughly equates to adding 500km per day since the save was created
      thumbnail = configInfo and configInfo.preview or '/ui/images/appDefault.png',
      connector = "ConName",
      reputationLvl = rentalVehicleInfo.reputationLvl,
      enabled = enabled,
      disableReason = disableReason,
      unlockInfo = unlockInfo,
      organizationName = organization.name,
      capacity = rentalVehicleInfo.capacity or {},
      sourceFacility = {type = "deliveryProvider", id = facility.id},
      loanType="work",
      spawnWhenCommitingCargo = markedForSpawningLoaners[id] and true or false,
      requiredSkillLevel = requiredSkillLevel > 0 and requiredSkillLevel or nil,
      requiredPoliceLevel = rentalVehicleInfo.requiredPoliceLevel and (requiredSkillLevel > 0 and requiredSkillLevel or nil) or nil,
    }
    if configInfo and configInfo.capacity then
      item.capacity = {}
      for _, cap in ipairs(configInfo.capacity) do
        if cap.type == "fluid" then
          table.insert(item.capacity, {
            icon = career_modules_delivery_parcelMods.getModifierIcon(cap.type),
            labelShort = string.format("%dL", cap.amount),
            labelLong = string.format("Fluids: %dL", cap.amount),
          })
        end
      end
    end

    if enabled and usesSkillUnlocks then
      local unlockParts = {}
      if requiredSkillLevel > 0 then
        table.insert(unlockParts, string.format("%s level %d", skillLabel, requiredSkillLevel))
      end
      if requiredReputationLvl ~= nil then
        local repLabel = organization.reputationLevels[requiredReputationLvl + 2]
        if repLabel then
          table.insert(unlockParts, string.format("Reputation '%s' with %s", repLabel.label, organization.name))
        end
      end
      if #unlockParts > 0 then
        item.unlockInfo = {
          type = "minLevel",
          icon = skillIcon,
          longLabel = "Requires " .. table.concat(unlockParts, " and "),
          shortLabel = requiredSkillLevel > 0 and string.format("lvl %d", requiredSkillLevel) or "rep"
        }
      end
    elseif enabled and not usesSkillUnlocks then
      local repLabel = string.format("%s (lvl %d)", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, rentalVehicleInfo.reputationLvl)
      item.unlockInfo = {
        type = "minLevel", icon = "peopleOutline", longLabel = string.format("Requires reputation: %s",repLabel), shortLabel = repLabel
      }
    end

    table.insert(ret, item)
  end
  return ret
end

M.spawnAndLoanVehicle = spawnAndLoanVehicle
M.returnVehicle = returnVehicle
M.getLoanedVehiclesByOrg = getLoanedVehiclesByOrg
M.formatLoanerOfferForUi = formatLoanerOfferForUi
M.formatSpawnedLoanersForUi = formatSpawnedLoanersForUi
M.getLoaningOrgsOfVehicle = getLoaningOrgsOfVehicle

M.onUpdate = onUpdate
M.onVehicleAdded = onVehicleAdded
M.onCareerActive = onCareerActive

return M
