-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'core_vehicleActivePooling'}

local logTag = "parking"

local searchRadius = 200 -- default radius for findParkingSpots
local keepClearRadius = 120 -- parked cars avoid activating within this radius
local nearSpawnMinDist = 18 -- nearby parked cars stay off the player's hood
local nearSpawnMaxDist = 50 -- nearby lots around the player
local nearSpawnCount = 3 -- a few around the player; the rest spawn farther out
local pileClearRadius = 12 -- only relocate cars that spawned on top of the player
local scatterMinDist = 45
local nearScatterMinDist = 16
local parkedVehIds, parkedVehData = {}, {}
local trackedVehData = {} -- parking tracking, can be used with the player vehicle

-- common functions --
local min = math.min
local max = math.max
local random = math.random

--------
local sites, vars
local aheadPos, lastPos, debugPos, tempVec = vec3(), vec3(), vec3(), vec3()
local focus
local active = false
local parkingSpotsAmount = 0
local parkingSpawnPending = false
local setupVehicles

M.debugLevel = 0

local function loadSites() -- loads sites data containing parking spots
  -- by default, the file "city.sites.json" in the root folder of the current level will be used
  if not gameplay_city then return end
  gameplay_city.loadSites()
  sites = gameplay_city.getSites()
  parkingSpotsAmount = sites and #sites.parkingSpots.sorted or 0
end

local function setSites(data) -- sets sites data, can override the default sites data
  if type(data) == "string" then
    if FS:fileExists(data) then
      sites = gameplay_sites_sitesManager.loadSites(data)
    end
  elseif type(data) == "table" and data.parkingSpots then -- assuming that given data is valid sites data
    sites = data
  else
    sites = nil
  end
  parkingSpotsAmount = sites and #sites.parkingSpots.sorted or 0
end

local function setState(val) -- activates or deactivates the parking system
  active = val and true or false
  if active then
    if not sites then
      loadSites()
    end
    focus = gameplay_traffic.getFocus()
    aheadPos:set(focus.pos)
    lastPos:set(aheadPos)
  end
end

local function getState()
  return active
end

local function getParkingSpots() -- returns a table of all current parking spots
  if not sites then
    loadSites()
  end
  return sites and sites.parkingSpots
end

local function setMapmgrTracking(vehId, state) -- enables or disables mapmgr tracking for a parked vehicle (details in comments below)
  if not vehId or not parkedVehData[vehId] or not parkedVehData[vehId].parkingSpotId then return end

  local parkingSpot = sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId]
  if not parkingSpot or parkingSpot.missing then return end

  if state == nil then state = parkingSpot.customFields.tags.street end -- by default, enable tracking if parking spot street tag is present
  if state then -- enables tracking, so that active traffic can dodge this vehicle
    getObjectByID(vehId):queueLuaCommand("mapmgr.enableTracking()")
  else -- disables tracking, to optimize performance
    getObjectByID(vehId):queueLuaCommand("mapmgr.disableTracking()")
  end
end

local function moveToParkingSpot(vehId, parkingSpot, lowPrecision) -- assigns a parked vehicle to a parking spot
  local obj = getObjectByID(vehId)
  local width, length = obj.initialNodePosBB:getExtents().x - 0.1, obj.initialNodePosBB:getExtents().y
  local backwards, offsetPos, offsetRot

  if parkingSpot.customFields.tags.forwards then
    backwards = false
  elseif parkingSpot.customFields.tags.backwards then
    backwards = true
  else
    backwards = random() > 0.75 + vars.neatness * 0.25 -- backwards direction is less common by default
  end

  if not parkingSpot.customFields.tags.perfect then -- randomize position and rotation slightly
    local offsetVal = 1 - square(vars.neatness)
    local xGap, yGap = max(0, parkingSpot.scl.x - width), max(0, parkingSpot.scl.y - length)
    local xRandom, yRandom = randomGauss3() / 3 - 0.5, clamp(randomGauss3() / 3 - (backwards and 0.75 or 0.25), -0.5, 0.5)
    offsetPos = vec3(xRandom * offsetVal * xGap, yRandom * offsetVal * yGap, 0)
    offsetRot = quatFromEuler(0, 0, (randomGauss3() / 3 - 0.5) * offsetVal * 0.25)
  end

  local options = {
    skipVehicleIntersectionCheck = true
  }
  parkingSpot:moveResetVehicleTo(vehId, lowPrecision, backwards, offsetPos, offsetRot, true, false, nil, options)
  if M.debugLevel > 0 then
    log("I", logTag, string.format("Teleported vehId %d to parking spot %d", vehId, parkingSpot.id))
  end

  local vehObj = getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand("electrics.setIgnitionLevel(0)")
  end

  if parkedVehData[vehId] then
    if parkedVehData[vehId].parkingSpotId then
      sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
    end
    
    parkingSpot.vehicle = vehId -- parking spot contains this vehicle
    parkedVehData[vehId].parkingSpotId = parkingSpot.id -- vehicle is assigned to this parking spot
    parkedVehData[vehId].activeRadius = 0
    parkedVehData[vehId]._teleport = nil

    setMapmgrTracking(vehId)
  end
end

local defaultParkingSpotSize = vec3(2.5, 6, 3)
local function checkDimensions(vehId) -- checks if the vehicle would fit in a standard sized parking spot
  local obj = getObjectByID(vehId)
  if not obj then return false end

  local extents = obj.initialNodePosBB:getExtents()
  return  extents.x <= defaultParkingSpotSize.x and
          extents.y <= defaultParkingSpotSize.y and
          extents.z <= defaultParkingSpotSize.z
end

local function checkParkingSpot(vehId, parkingSpot, minDist, maxDist) -- checks if a parking spot is ready to use for a parked vehicle
  local obj = getObjectByID(vehId or 0)
  minDist = minDist or 0
  maxDist = maxDist or 1e12

  if not parkingSpot or parkingSpot.missing then return false end

  local dist = parkingSpot.pos:squaredDistance(focus.pos)
  if dist < square(minDist) or dist > square(maxDist) then
    return false
  end

  if parkingSpot.vehicle or parkingSpot.customFields.tags.banned or parkingSpot:hasAnyVehicles() or not obj then
    return false
  end

  for _, veh in ipairs(getAllVehicles()) do
    if veh:getActive() then
      local trafficClearRadius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) -- custom radius that prevents parked cars from respawning too near
      if trafficClearRadius then
        tempVec:set(be:getObjectPositionXYZ(veh:getId()))
        if parkingSpot.pos:squaredDistance(tempVec) <= square(trafficClearRadius) then
          return false
        end
      end
    end
  end

  if parkingSpot:vehicleFits(vehId) then
    -- ensure that the parking spot is not too oversized for the vehicle
    local size = obj.initialNodePosBB:getExtents()
    local psSize = parkingSpot.scl
    if size.x / psSize.x < 0.5 or size.y / psSize.y < 0.5 then
      return false
    end
  else
    return false
  end

  return true
end

local function findParkingSpots(pos, minRadius, maxRadius) -- finds and returns a sorted array of parking spot objects and distances
  if not sites then return {} end
  pos = pos or core_camera.getPosition()
  minRadius = minRadius or 0
  maxRadius = maxRadius or searchRadius

  local psList = sites:getRadialParkingSpots(pos, minRadius, maxRadius)
  -- each entry in psList contains: v.ps (parking spot object), v.squaredDistance (squared distance to parking spot)

  if M.debugLevel > 0 then
    log("I", logTag, string.format("Found and validated %d parking spots in area", #psList))
  end
  table.sort(psList, function(a, b) return a.squaredDistance < b.squaredDistance end) -- sorts from closest to farthest

  return psList
end

local function updateParkingSpots(psList, pos) -- updates the distances of the parking spots in the cached list
  if not psList or type(psList[1]) ~= "table" then return psList end
  for i, v in ipairs(psList) do
    psList[i].squaredDistance = pos:squaredDistance(v.ps.pos)
  end

  table.sort(psList, function(a, b) return a.squaredDistance < b.squaredDistance end) -- sorts from closest to farthest
  return psList
end

local emptyFilters = {}
local defaultFilters = {useProbability = true}
local function filterParkingSpots(psList, filters) -- filter the sorted list of parking spots (as returned by findParkingSpots)
  if not psList or type(psList[1]) ~= "table" then return psList end
  filters = filters or defaultFilters

  local psCount = #psList
  local timeDay = 0

  if filters.useProbability then
    local timeObj = core_environment.getTimeOfDay()
    if timeObj and timeObj.time then
      timeDay = timeObj.time
    end
  end

  for i = psCount, 1, -1 do
    local ps = psList[i].ps
    local remove = false

    if ps.customFields.tags.banned then
      remove = true
    end

    if filters.standardSize then
      if ps.scl.x > 3 or ps.scl.y > 8 then -- arbitrary width and length limits for standard parking spots
        remove = true
      end
    end

    if filters.checkVehicles then -- strict but slow check for other vehicles occupying this spot
      if ps:hasAnyVehicles() then
        remove = true
      end
    end

    if filters.useProbability then
      local prob = ps.customFields:has("probability") and ps.customFields:get("probability") or vars.baseProbability
      if type(prob) ~= "number" then prob = 1 end
      prob = prob * vars.baseProbability

      local dayValue = 0.25 + math.abs(timeDay - 0.5) * 1.5 -- max 1 for midday, min 0.25 for midnight
      local timeDayCoef = dayValue

      if ps.customFields.tags.nightTime then
        local nightValue = 1 - math.abs(timeDay - 0.5) * 1.5 -- opposite of dayValue
        if ps.customFields.tags.dayTime then
          timeDayCoef = max(timeDayCoef, nightValue)
        else
          timeDayCoef = nightValue
        end
      end
      prob = prob * timeDayCoef

      if prob <= random() then
        remove = true
      end
    end

    if remove then
      table.remove(psList, i)
    end
  end

  if M.debugLevel > 0 then
    log("I", logTag, string.format("Filtered and accepted %d / %d parking spots", #psList, psCount))
  end

  return psList
end

local function positionTooCloseToParked(pos, minDist, ignoreVehId)
  local minSq = square(minDist or scatterMinDist)
  for _, vehId in ipairs(parkedVehIds) do
    if vehId ~= ignoreVehId then
      local obj = getObjectByID(vehId)
      if obj and obj:getPosition():squaredDistance(pos) < minSq then
        return true
      end
    end
  end
  return false
end

local function pickSpreadSpots(psList, targetCount, minDist)
  local picked = {}
  minDist = minDist or scatterMinDist
  local minSq = square(minDist)
  for _, entry in ipairs(psList or {}) do
    if #picked >= targetCount then
      break
    end
    local ps = entry.ps
    if ps and ps.pos and not positionTooCloseToParked(ps.pos, minDist) then
      local farEnough = true
      for _, prev in ipairs(picked) do
        if ps.pos:squaredDistance(prev.ps.pos) < minSq then
          farEnough = false
          break
        end
      end
      if farEnough then
        picked[#picked + 1] = entry
      end
    end
  end
  return picked
end

local function getRandomParkingSpots(originPos, minDist, maxDist, targetCount, filters) -- returns a list of random parking spots, with a bias for origin position
  if not sites then return {} end
  originPos = originPos or core_camera.getPosition()
  minDist = minDist or 0
  maxDist = maxDist or 10000
  local step = max(20, min((maxDist - minDist) / 4, 100))
  local radius = minDist
  local psList, psCount = {}, 0
  if not targetCount or targetCount <= 0 then -- targetCount is optional
    targetCount = math.huge
    step = maxDist - minDist
  end
  while psCount < targetCount and radius < maxDist do
    radius = min(maxDist, radius + step)
    psList = findParkingSpots(originPos, minDist, radius)
    psList = filterParkingSpots(psList, filters)
    psCount = #psList
  end

  if psCount == 0 then return {} end
  if targetCount == math.huge then
    targetCount = max(1, math.ceil(psCount / 4)) -- auto minimum count
  end

  local psMainList, psAltList = {}, {} -- main list contains the most favorable parking spots, alt list contains all others
  local ratio = min(0.95, 1 - (targetCount / psCount)) -- ratio of selectable parking spots

  for i, ps in ipairs(psList) do
    if random() >= lerp(ratio, 1, square(i / psCount)) then -- value is lower for nearer parking spots (lower index means shorter distance)
      table.insert(psMainList, ps)
    else
      table.insert(psAltList, ps)
    end
  end

  psList = arrayConcat(psMainList, psAltList)
  local spreadDist = (filters and filters.scatterMinDist) or scatterMinDist
  if targetCount and targetCount ~= math.huge then
    psList = pickSpreadSpots(psList, targetCount, spreadDist)
  end
  return psList
end

local function forceTeleport(vehId, pos, minDist, maxDist) -- forces a parked car to teleport to a new parking spot
  if not vars.enableRespawn then return end
  if not parkedVehData[vehId] or parkedVehData[vehId].ignoreForceTeleport then return end

  pos = pos or core_camera.getPosition()

  local psList = getRandomParkingSpots(pos, minDist, maxDist, 1, {checkVehicles = true})
  local psId = nil
  for _, psData in ipairs(psList) do
    local ps = psData.ps
    if checkParkingSpot(vehId, ps, minDist, maxDist) then
      psId = ps.id
      if parkedVehData[vehId].parkingSpotId then
        sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
        parkedVehData[vehId].parkingSpotId = nil
      end

      moveToParkingSpot(vehId, ps, not getObjectByID(vehId):isReady())
      break
    end
  end

  if not psId then
    gameplay_traffic.forceTeleport(vehId, nil, nil, 10000, 10000) -- out of map; this should be unlikely
  end
end

local function scatterParkedCars(vehIds, minDist, maxDist) -- randomly teleports all parked vehicles to parking spots
  vehIds = vehIds or parkedVehIds
  local psList = getRandomParkingSpots(focus and focus.pos, minDist, maxDist, #vehIds, {checkVehicles = true})
  for i, vehId in ipairs(vehIds) do
    if psList[i] and checkParkingSpot(vehId, psList[i].ps, minDist, maxDist) then
      moveToParkingSpot(vehId, psList[i].ps, not getObjectByID(vehId):isReady())
    else
      forceTeleport(vehId, nil, minDist, maxDist) -- alternative method (not efficient if this needs to be called)
    end
  end
end

local function enableTracking(vehId, autoDisable) -- enables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  if not getObjectByID(vehId) then return end

  setState(true)

  trackedVehData[vehId] = {
    isOversized = checkDimensions(vehId),
    autoDisableTracking = autoDisable and true or false,
    inside = false,
    preParked = false,
    parked = false,
    event = "none",
    aheadPos = vec3(),
    focusPos = vec3(),
    maxDist = 80,
    parkingTimer = 0
  }
end

local function disableTracking(vehId) -- disables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  trackedVehData[vehId] = nil
end

local function getTrackingData()
  return trackedVehData
end

local function getCurrentParkingSpot(vehId) -- returns the parking spot id of a properly parked vehicle (no tracked data needed)
  vehId = vehId or be:getPlayerVehicleID(0)
  if not getObjectByID(vehId) then return end

  if trackedVehData[vehId] then
    if trackedVehData[vehId].preParked then
      return trackedVehData[vehId].parkingSpotId -- existing tracked data
    end
  else
    local obj = getObjectByID(vehId)
    if not obj then return end

    local psList = findParkingSpots(obj:getPosition(), 0, 15)
    if psList[1] and psList[1].ps:vehicleFits(vehId) and psList[1].ps:checkParking(vehId, vars.precision) then
      return psList[1].ps.id
    end
  end
end

local function resetParkingVars() -- resets parking variables to default
  vars = {
    precision = 0.8, -- parking precision required for valid parking
    neatness = 0, -- generated parked vehicle precision
    radiusCoef = 1, -- active radius multiplier
    baseProbability = 0.75, -- probability coefficient for spawning in parking spots (usually from 0 to 1; default 0.75 for nice scattering in parking lots)
    activeAmount = math.huge, -- number of active (visible) vehicles at a time
    enableRespawn = true  -- master respawn state; if false, disables all methods of respawning vehicles
  }
end
resetParkingVars()

local function isNoParkedMode()
  local s = rawget(_G, 'overhaul_settings')
  return s and s.getSetting and s.getSetting('noParkedMode')
end

local function getParkedCarCap()
  if isNoParkedMode() then
    return 0
  end
  return gameplay_vehicleRotationPool.getParkedTarget()
end

local function enforceParkedCarCap()
  local cap = getParkedCarCap()
  if cap == nil then return end

  if #parkedVehIds > cap then
    local excess = #parkedVehIds - cap
    for i = 1, excess do
      local vehId = parkedVehIds[#parkedVehIds]
      if vehId then
        gameplay_vehicleRotationPool.retireParked(vehId)
      end
    end
    log("I", logTag, string.format("Processed %d extra parked cars to honor cap of %d", excess, cap))
  end
end

local function setParkingVars(data, reset) -- sets parking related variables
  if reset then resetParkingVars() end
  if type(data) ~= "table" then return end

  if data.radiusCoef then
    data.radiusCoef = clamp(data.radiusCoef, 0.25, 1000)
    for _, veh in pairs(parkedVehData) do
      veh.activeRadius = 0
    end
  end

  vars = tableMerge(vars, data)

end

local function setActiveAmount(amount) -- sets the maximum amount of active (visible) vehicles
  amount = amount or math.huge
  setParkingVars({activeAmount = amount})
end

local function getParkingVars() -- gets parking related variables
  return vars
end

local function getParkedCarsAmount(activeOnly)
  return activeOnly and min(vars.activeAmount, #parkedVehIds) or #parkedVehIds
end

local function getParkedCarsList()
  return parkedVehIds
end

local function getParkedCarsData()
  return parkedVehData
end

local function getVehicleSpawnData(obj)
  local metallicPaintData = obj:getMetallicPaintData() or {}
  return {
    model = obj.jbeam or obj.JBeam or obj:getField('JBeam', '0'),
    config = obj.partConfig,
    pos = obj:getPosition(),
    rot = quatFromDir(vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp())),
    paint = createVehiclePaint(obj.color, metallicPaintData[1]),
    paint2 = createVehiclePaint(obj.colorPalette0, metallicPaintData[2]),
    paint3 = createVehiclePaint(obj.colorPalette1, metallicPaintData[3]),
    licenseText = obj:getDynDataFieldbyName("licenseText", 0),
    vehicleName = obj:getField('name', '')
  }
end

local function spawnVehicleFromData(data)
  if not data or not data.model then return end
  local options = {
    config = data.config,
    pos = data.pos,
    rot = data.rot,
    paint = data.paint,
    paint2 = data.paint2,
    paint3 = data.paint3,
    licenseText = data.licenseText,
    vehicleName = data.vehicleName,
    autoEnterVehicle = false,
    canSpawnAnotherVehicleCheck = false,
    centeredPosition = true
  }
  local veh = core_vehicles.spawnNewVehicle(data.model, options)
  return veh and veh:getID()
end

local bbCenter, vehDirection, bbHalfExtents = vec3(), vec3(), vec3()
local result = {}
local function trackParking(vehId) -- tracks parking status of a driving vehicle
  local valid = false
  table.clear(result)
  result.cornerCount = 0
  local obj = getObjectByID(vehId or 0)
  if not obj then return valid, result end

  local vehData = trackedVehData[vehId]
  bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  vehDirection:set(obj:getDirectionVectorXYZ())
  bbHalfExtents:set(be:getObjectOOBBHalfExtentsXYZ(vehId))

  vehDirection:setScaled(bbHalfExtents.y)
  vehData.aheadPos:setAdd2(bbCenter, vehDirection) -- tracks the position ahead of the vehicle

  local maxDist = M.debugLevel >= 3 and 400 or vehData.maxDist
  if vehData.focusPos:squaredDistance(vehData.aheadPos) >= square(maxDist * 0.5) then -- focus pos and nearby parking spots low frequency update
    vehData.psList = findParkingSpots(vehData.aheadPos, 0, maxDist)
    vehData.psList = filterParkingSpots(vehData.psList, emptyFilters)
    vehData.focusPos:set(vehData.aheadPos)
  end

  vehData.psList = updateParkingSpots(vehData.psList, vehData.aheadPos) or {}

  if M.debugLevel > 0 then
    for _, v in ipairs(vehData.psList) do
      local ps = v.ps
      local psDirVec = vec3(0, 1, 0):rotated(ps.rot)
      local dColor = ps.vehicle and ColorF(1, 0.5, 0.5, 0.2) or ColorF(1, 1, 1, 0.2)
      if ps.vehicle == vehId then dColor = ColorF(0.5, 1, 0.5, 0.2) end
      debugDrawer:drawSquarePrism(ps.pos - psDirVec * ps.scl.y * 0.5, ps.pos + psDirVec * ps.scl.y * 0.5, Point2F(0.6, ps.scl.x), Point2F(0.6, ps.scl.x), dColor)
    end
  end

  local bestPs
  for _, v in ipairs(vehData.psList) do -- nearest parking spot
    if v.ps:vehicleFits(vehId) and (not v.ps.vehicle or v.ps.vehicle == vehId) then
      bestPs = v.ps
      break
    end
  end

  if bestPs then
    result.parkingSpotId = bestPs.id
    result.parkingSpot = bestPs

    if not bestPs.vertices[1] then bestPs:calcVerts() end
    valid, result.corners = bestPs:checkParking(vehId, vars.precision) -- checks if all vehicle corners are inside the parking spot with respect to the precision
    for _, v in ipairs(result.corners) do
      if v then
        result.cornerCount = result.cornerCount + 1
      end
    end

    if M.debugLevel >= 2 then
      for i, v in ipairs(result.corners) do
        local dColor = v and ColorF(0.3, 1, 0.3, 0.5) or ColorF(1, 0.3, 0.3, 0.5)
        debugDrawer:drawCylinder(bestPs.vertices[i], bestPs.vertices[i] + vec3(0, 0, 10), 0.05, dColor)
      end
    end
  end

  return valid, result
end

local function insertVehicle(vehId) -- inserts a new vehicle into the parked cars table
  local obj = getObjectByID(vehId)
  if obj then
    if obj.ignoreParking then
      log('I', logTag, string.format('Ignoring parking vehicle due to blocking flag: %d', vehId))
      return
    end

    if #parkedVehIds >= getParkedCarCap() then return end
    if parkedVehData[vehId] then return end

    table.insert(parkedVehIds, vehId)

    local psId = getCurrentParkingSpot(vehId)
    if psId then
      sites.parkingSpots.objects[psId].vehicle = vehId -- saves the vehicle id to this spot
    end

    parkedVehData[vehId] = {
      parkingSpotId = psId, -- current parking spot id
      activeRadius = 0, -- radius that keeps the vehicle active if player is near
      randomPaint = true -- randomizes paint after respawning
    }

    setMapmgrTracking(vehId)
  end
end

local function removeVehicle(vehId) -- removes a vehicle from the parked cars table
  if not vehId or not parkedVehData[vehId] then return end

  local psId = parkedVehData[vehId].parkingSpotId
  if psId and sites and sites.parkingSpots and sites.parkingSpots.objects[psId] then
    sites.parkingSpots.objects[psId].vehicle = nil
  end
  parkedVehData[vehId] = nil
  parkedVehIds = tableKeysSorted(parkedVehData)
end

local function deleteVehicles(amount)
  local total = #parkedVehIds
  local count = min(amount or total, total)
  for i = total, total - count + 1, -1 do
    local vehId = parkedVehIds[i]
    local obj = vehId and getObjectByID(vehId)
    if obj then
      obj:delete()
    end
  end

  if not amount or amount >= total then
    gameplay_vehicleRotationPool.deleteParkedVehicles()
  end
end

local function getPlayerPos()
  local pid = be:getPlayerVehicleID(0)
  if pid and pid ~= -1 then
    local obj = getObjectByID(pid)
    if obj then
      return obj:getPosition(), pid
    end
  end
end

-- Career load picks parking spots before the player vehicle exists, so initial
-- transforms are often relative to the loading camera. Pull a few cars into
-- real nearby lots once the player is actually in the world.
local function ensureNearbyParkedCars(origin)
  if not origin or not parkedVehIds[1] then return end
  local want = min(nearSpawnCount, #parkedVehIds)
  if want <= 0 then return end

  local nearCount, farIds = 0, {}
  for _, vehId in ipairs(parkedVehIds) do
    local obj = getObjectByID(vehId)
    if obj then
      local dSq = obj:getPosition():squaredDistance(origin)
      if dSq >= square(nearSpawnMinDist) and dSq <= square(nearSpawnMaxDist) then
        nearCount = nearCount + 1
      else
        farIds[#farIds + 1] = vehId
      end
    end
  end

  local need = want - nearCount
  if need <= 0 then return end

  local spots = getRandomParkingSpots(origin, nearSpawnMinDist, nearSpawnMaxDist, need, {checkVehicles = true, standardSize = true, scatterMinDist = nearScatterMinDist})
  local moved = 0
  for i = 1, need do
    local vehId = farIds[i]
    local entry = spots[i]
    if not vehId or not entry or not entry.ps then break end
    local obj = getObjectByID(vehId)
    moveToParkingSpot(vehId, entry.ps, obj and not obj:isReady())
    moved = moved + 1
  end
  if moved > 0 then
    log("I", logTag, string.format("Moved %d parked cars into nearby lots around the player", moved))
  end
end

local function activate(vehIds) -- activates a group of vehicles, to allow them to teleport to new parking spots
  setState(true)
  if not sites or not vehIds then
    setState(false)
    return
  end

  for _, vehId in ipairs(vehIds) do
    insertVehicle(vehId)
  end

  if not parkedVehIds[1] then
    setState(false)
    return
  end

  enforceParkedCarCap()

  local playerPos, playerId = getPlayerPos()
  local focusPos = playerPos or (focus and focus.pos) or core_camera.getPosition()
  local tooClose = {}
  for _, vehId in ipairs(parkedVehIds) do
    local obj = getObjectByID(vehId)
    if obj and obj:getPosition():squaredDistance(focusPos) < square(pileClearRadius) then
      tooClose[#tooClose + 1] = vehId
    end
  end
  if tooClose[1] then
    scatterParkedCars(tooClose, keepClearRadius)
  end

  ensureNearbyParkedCars(playerPos or focusPos)

  if playerId and core_camera.setVehicleCameraByIndexOffset then
    core_camera.setVehicleCameraByIndexOffset(0, 0)
  end

  extensions.hook("onParkingVehiclesActivated", parkedVehIds)

  local amount, activeAmount = getParkedCarsAmount(), getParkedCarsAmount(true)
  log('I', logTag, string.format('Parking system started with %d active / %d total vehicles', activeAmount, amount))
end

local function deactivate() -- deactivates all parked vehicles
  setState(false)
  gameplay_vehicleRotationPool.deactivateParking()
  table.clear(parkedVehIds)
  table.clear(parkedVehData)

  extensions.hook("onParkingVehiclesDeactivated")
end

setupVehicles = function(amount, options) -- spawns and prepares simple parked vehicles
  options = options or {}

  if parkingSpawnPending then
    log("I", logTag, "Ignoring extra parked vehicle spawn; one is already in progress")
    return false
  end

  if not options.keepCurrent then
    deleteVehicles() -- clear current parked vehicles
  end

  if not sites then
    loadSites()
  end

  amount = amount or -1
  if amount == -1 then
    amount = settings.getValue("trafficParkedAmount")
    if amount == 0 then
      setMaxVehicleAmountForTraffic() -- fix parking amount if zero
      amount = settings.getValue("trafficParkedAmount") -- get fixed amount
    end
  end

  local spawnAmount = amount > 0 and (gameplay_vehicleRotationPool and gameplay_vehicleRotationPool.getPoolSpawnAmount(amount) or amount) or 0
  local group
  if type(options.vehGroup) == "table" then
    group = options.vehGroup
  else
    local params = gameplay_traffic_trafficUtils.getBaseGroupParams()
    params.allConfigs = true
    params.filters.Type = {propparked = 1}
    params.minPop = 0

    group = core_multiSpawn.createGroup(spawnAmount, params)
  end

  if spawnAmount <= 0 then
    log("I", logTag, "Parked vehicle amount to spawn is zero, now ignoring parked cars")
    return false
  elseif not group or not group[1] then
    log("I", logTag, "Parked vehicle group is empty!")
    return false
  end

  local playerPos, playerId = getPlayerPos()
  if gameplay_traffic.getFocus().auto and playerId then
    gameplay_traffic.setFocus('vehicle', {vehId = playerId})
  end

  local origin = options.pos or playerPos
  if not origin then
    local focusNow = gameplay_traffic.getFocus()
    origin = (focusNow and focusNow.pos) or core_camera.getPosition()
  end

  local filters = {checkVehicles = true, standardSize = true, scatterMinDist = scatterMinDist}
  local nearFilters = {checkVehicles = true, standardSize = true, scatterMinDist = nearScatterMinDist}
  local transforms, usedSpots = {}, {}
  local function appendSpotTransforms(psList, limit)
    for _, entry in ipairs(psList or {}) do
      if #transforms >= limit then break end
      local ps = entry.ps
      if ps and ps.id and not usedSpots[ps.id] then
        usedSpots[ps.id] = true
        table.insert(transforms, {pos = ps.pos, rot = ps.rot})
      end
    end
  end

  local nearWanted = options.farOnly and 0 or min(spawnAmount, nearSpawnCount)
  if nearWanted > 0 then
    appendSpotTransforms(getRandomParkingSpots(origin, nearSpawnMinDist, nearSpawnMaxDist, nearWanted, nearFilters), nearWanted)
  end
  local farWanted = spawnAmount - #transforms
  if farWanted > 0 then
    appendSpotTransforms(getRandomParkingSpots(origin, keepClearRadius, nil, farWanted, filters), spawnAmount)
  end

  if transforms[1] then
    lastPos:set(transforms[1].pos)
  else
    if not options.bypassChecks then
      log("I", logTag, "No parking spots found, now ignoring parked cars")
      return false
    end
  end

  parkingSpawnPending = true
  core_multiSpawn.spawnGroup(group, spawnAmount, {name = "autoParking", mode = "roadBehind", gap = 50, customTransforms = transforms, randomPaints = true})

  return true
end

local function resetAll() -- resets everything
  active = false
  sites = nil
  parkingSpotsAmount = 0
  parkingSpawnPending = false
  gameplay_vehicleRotationPool.resetAll()
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  table.clear(trackedVehData)
  resetParkingVars()
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == "autoParking" then
    parkingSpawnPending = false
    activate(vehList)
  end
end

local function onVehicleDestroyed(vehId)
  if parkedVehData[vehId] then
    table.remove(parkedVehIds, arrayFindValueIndex(parkedVehIds, vehId))
    if sites and parkedVehData[vehId].parkingSpotId then
      sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
    end
    parkedVehData[vehId] = nil
  end
  if trackedVehData[vehId] then
    disableTracking(vehId)
  end
end


local vehPos = vec3()
local function onUpdate(dt, dtSim)
  if not be:getEnabled() then return end
  if not active or not sites or (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then return end

  tempVec:set(focus.dirVec)
  tempVec.z = 0
  tempVec:normalize()
  tempVec:setScaled2(tempVec, clamp(focus.speed * 2, 10, 100))
  aheadPos:setAdd2(focus.pos, tempVec)
  aheadPos.z = 0

  for vehId, data in pairs(trackedVehData) do
    local valid, pData = trackParking(vehId)
    data.parkingSpotId = pData.parkingSpotId
    data.parkingSpot = pData.parkingSpot

    if not valid then
      data.parkingTimer = 0
    end

    if pData.cornerCount >= 2 then -- at least two vehicle corners
      data.lastParkingSpotId = data.parkingSpotId
    end

    if not data.inside and pData.cornerCount > 0 then -- entered parking spot bounds
      data.inside = true
      data.event = "enter"
      extensions.hook("onVehicleParkingStatus", vehId, data)
    elseif data.inside and pData.cornerCount == 0 then -- exited parking spot bounds
      data.inside = false
      data.event = "exit"
      extensions.hook("onVehicleParkingStatus", vehId, data)
    end

    if data.lastParkingSpotId then
      if not data.parked and valid then
        data.preParked = true
        data.parkingTimer = data.parkingTimer + dtSim
        if data.parkingTimer >= 0.5 then -- valid parking (after a small delay)
          data.parked = true
          data.event = "valid"
          sites.parkingSpots.objects[data.lastParkingSpotId].vehicle = vehId
          extensions.hook("onVehicleParkingStatus", vehId, data)

          if data.autoDisableTracking then
            disableTracking(vehId)
          end
        end
      elseif data.preParked and not valid then -- invalid parking
        data.preParked = false
        data.parked = false
        data.event = data.inside and "invalid" or "exit"
        sites.parkingSpots.objects[data.lastParkingSpotId].vehicle = nil
        extensions.hook("onVehicleParkingStatus", vehId, data)
      end
    end
  end

end

local function onClientStartMission()
end

local function onClientEndMission()
  resetAll()
end

local function onSerialize(options)
  options = type(options) == "table" and options or {}
  local vehicleSpawnData, vehicleSpawnOrder
  if options.despawnVehicles then
    vehicleSpawnData = {}
    vehicleSpawnOrder = {}
    if options.debugVehicleStashing then
      log("D", logTag, "Serializing parked vehicles for mission despawn stash")
    end
    for _, vehId in ipairs(parkedVehIds) do
      local obj = getObjectByID(vehId)
      if obj and vehId ~= options.exceptVehicleId then
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Capturing parked vehicle for mission despawn stash: %d", vehId))
        end
        vehicleSpawnData[vehId] = getVehicleSpawnData(obj)
        table.insert(vehicleSpawnOrder, vehId)
      elseif obj and vehId == options.exceptVehicleId and options.debugVehicleStashing then
        log("D", logTag, string.format("Skipping mission player vehicle parking despawn: %d", vehId))
      end
    end
  end

  local data = {active = active, debugLevel = M.debugLevel, parkedVehIds = deepcopy(parkedVehIds), trackedVehIds = tableKeys(trackedVehData), vars = deepcopy(vars), vehicleSpawnData = vehicleSpawnData, vehicleSpawnOrder = vehicleSpawnOrder}
  resetAll()

  if vehicleSpawnOrder then
    for _, vehId in ipairs(vehicleSpawnOrder) do
      local obj = getObjectByID(vehId)
      if obj then
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Deleting parked vehicle after mission stash capture: %d", vehId))
        end
        obj:delete()
      end
    end
  end

  return data
end

local function onDeserialized(data, options)
  options = type(options) == "table" and options or {}
  local idMap = {}
  if options.respawnVehicles and data.vehicleSpawnData then
    if options.debugVehicleStashing then
      log("D", logTag, "Respawning parked vehicles from mission stash")
    end
    for _, oldId in ipairs(data.vehicleSpawnOrder or tableKeysSorted(data.vehicleSpawnData)) do
      local newId = spawnVehicleFromData(data.vehicleSpawnData[oldId])
      if newId then
        idMap[oldId] = newId
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Respawned parked vehicle from mission stash: oldId=%d newId=%d", oldId, newId))
        end
      else
        log("W", logTag, string.format("Unable to respawn serialized parked vehicle: %d", oldId))
      end
    end
  end

  local restoredParkedVehIds = {}
  for _, vehId in ipairs(data.parkedVehIds or {}) do
    table.insert(restoredParkedVehIds, idMap[vehId] or vehId)
  end

  activate(restoredParkedVehIds)
  for _, v in ipairs(data.trackedVehIds or {}) do
    enableTracking(idMap[v] or v)
  end
  setParkingVars(data.vars)
  active = data.active
  M.debugLevel = data.debugLevel
end

-- public interface
M.setSites = setSites
M.setState = setState
M.getState = getState
M.setupVehicles = setupVehicles
M.insertVehicle = insertVehicle
M.removeVehicle = removeVehicle
M.processVehicles = activate
M.activate = activate
M.deactivate = deactivate
M.deleteVehicles = deleteVehicles
M.getParkedCarsAmount = getParkedCarsAmount
M.getParkingAmount = getParkedCarsAmount
M.getParkedCarsList = getParkedCarsList
M.getParkedCarsData = getParkedCarsData
M.enableTracking = enableTracking
M.disableTracking = disableTracking
M.resetAll = resetAll

M.getTrackingData = getTrackingData
M.getParkingSpots = getParkingSpots
M.findParkingSpots = findParkingSpots
M.filterParkingSpots = filterParkingSpots
M.getRandomParkingSpots = getRandomParkingSpots
M.checkParkingSpot = checkParkingSpot
M.moveToParkingSpot = moveToParkingSpot
M.getCurrentParkingSpot = getCurrentParkingSpot
M.forceTeleport = forceTeleport
M.scatterParkedCars = scatterParkedCars
M.setActiveAmount = setActiveAmount
M.setParkingVars = setParkingVars
M.getParkingVars = getParkingVars

M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
