-- Vehicle Rotation Pool: 4-Pool Isolated Fleet Architecture

local M = {}
M.dependencies = {'gameplay_traffic'}

local logTag = 'vehicleRotationPool'

local POLICE_KEYWORDS = {
  'police', 'sheriff', 'interceptor'
}

local SPECIALIZED_KEYWORDS = {
  'taxi', 'cab',
  'ambulance', 'ems', 'paramedic',
  'fire', 'rescue', 'delivery', 'service'
}

-- 4 Isolated Pools
local driveActivePool = {}    -- (Set: [vehId] = true) - active traffic driving on roads
local driveInactivePool = {}  -- (FIFO queue: [1, 2, ...]) - dormant traffic vehicles
local parkedActivePool = {}   -- (Set: [vehId] = true) - active parked vehicles in stalls
local parkedInactivePool = {} -- (FIFO queue: [1, 2, ...]) - dormant parked vehicles
local classifiedVehicles = {} -- (Set: [vehId] = true) - vehicles already classified
local policeVehicles = {}     -- (Set: [vehId] = true) - police cruisers marked at registration
local specializedVehicles = {}-- (Set: [vehId] = true) - specialized livery/service vehicles

-- Update timers
local tickTimer = 0
local TICK_INTERVAL = 2.0 -- Check fleet health and spawn 1 car per 2.0 seconds
local captureTimer = 0
local CAPTURE_INTERVAL = 0.25 -- 4 Hz check for queued/despawned vehicles
local spawnDriveTick = true -- Alternates: odd ticks (true) spawn drive, even ticks (false) spawn parked

-- State vriables
local eventStatus = false
local cachedFleetFloor = nil
local origDeleteVehicles = nil
local origTrafficSetActiveAmount = nil
local origParkingSetActiveAmount = nil

-- Static buffers for zero per-tick allocations
local playerPosVec = vec3()
local toRetireParked = {}
local toRetireDrive = {}
local spotFilterOptions = { checkVehicles = true, standardSize = true }

-- Distance thresholds and limits
local MIN_SPAWN_DIST = 125                   -- spawn distance from player (meters)
local MAX_SPAWN_DIST = MIN_SPAWN_DIST  + 60  -- maximum distance to player for any vehicle spawn
local DESPAWN_DIST = MAX_SPAWN_DIST + 30     -- radius beyond which vehicles can retire
local DESPAWN_DIST_SQ = DESPAWN_DIST * DESPAWN_DIST


-- ============================================================================
-- Fleet Metrics & Target Resolvers
-- ============================================================================

local function countKeys(tbl)
  local c = 0
  for _ in pairs(tbl) do c = c + 1 end
  return c
end

local function getFleetReserveFloor()
  if cachedFleetFloor then return cachedFleetFloor end

  -- Check user setting override in overhaul_settings first (fail-open)
  local s = rawget(_G, 'overhaul_settings')
  if s and s.getSetting then
    local customFloor = tonumber(s.getSetting('rotationPoolFleetSize'))
    if customFloor and customFloor > 0 then
      cachedFleetFloor = math.floor(customFloor)
      log('I', logTag, string.format('Using custom rotation pool fleet reserve floor from settings: %d', cachedFleetFloor))
      return cachedFleetFloor
    end
  end

  local ramGB = 16
  local mem = Engine.Platform and Engine.Platform.getMemoryInfo and Engine.Platform.getMemoryInfo()
  if mem and mem.osPhysAvailable and mem.osPhysAvailable > 0 then
    ramGB = mem.osPhysAvailable / (1024 * 1024 * 1024)
  end

  local vramGB = 8
  if Engine.Render and Engine.Render.getMemoryInfo then
    local gMem = Engine.Render.getMemoryInfo()
    if gMem and gMem.valid then
      local vBytes = (gMem.isDedicatedMemory and gMem.dedicatedBytes and gMem.dedicatedBytes > 0 and gMem.dedicatedBytes)
        or (gMem.dedicatedBytes and gMem.dedicatedBytes > 0 and gMem.dedicatedBytes)
        or (gMem.budgetBytes and gMem.budgetBytes > 0 and gMem.budgetBytes)
        or gMem.sharedBytes
      if vBytes and vBytes > 0 then
        vramGB = vBytes / (1024 * 1024 * 1024)
      end
    end
  end

  -- Dynamic hardware tiering calibrated for available (free) RAM and VRAM
  if ramGB >= 16 and vramGB >= 8 then
    cachedFleetFloor = 20 -- Tier 1: Deep reserve (40 total world cars; 32GB+ systems with >= 16GB free)
  elseif ramGB >= 9 and vramGB >= 5 then
    cachedFleetFloor = 14 -- Tier 2: Balanced reserve (28 total world cars; 16GB systems with >= 9GB free)
  elseif ramGB >= 5 and vramGB >= 3 then
    cachedFleetFloor = 8  -- Tier 3: Light reserve (16 total world cars; 12GB systems with >= 5GB free)
  else
    cachedFleetFloor = 0  -- Tier 4: Zero reserve (Active only, lowest memory overhead)
  end

  log('I', logTag, string.format('Hardware detected: %.1f GB free RAM, %.1f GB free VRAM -> Dynamic fleet reserve floor: %d per circuit',
    ramGB, vramGB, cachedFleetFloor))
  return cachedFleetFloor
end

local function getDespawnDist()
  return DESPAWN_DIST
end

local function getPoolSpawnAmount(amount)
  amount = tonumber(amount) or 0
  if amount <= 0 then return 0 end
  local floor = getFleetReserveFloor()
  return math.max(floor, amount)
end

local function getCounts()
  return countKeys(driveActivePool), #driveInactivePool, countKeys(parkedActivePool), #parkedInactivePool
end

local function getTotalCount()
  return countKeys(driveActivePool) + #driveInactivePool + countKeys(parkedActivePool) + #parkedInactivePool
end

local function isEventBlockingTraffic()
  local result = false
  -- 1. Freeroam race / AI race session in progress
  if gameplay_events_freeroam_session and gameplay_events_freeroam_session.mActiveRace then
    result = true
  -- 2. Foreground career mission / scenario in progress (suppress only if mission does not use traffic)
  elseif gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId then
    local mId = gameplay_missions_missionManager.getForegroundMissionId()
    if mId then
      local mission = gameplay_missions_missions and gameplay_missions_missions.getMissionById and gameplay_missions_missions.getMissionById(mId)
      local trafficSetup = mission and mission.setupModules and mission.setupModules.traffic
      if not (trafficSetup and trafficSetup.useTraffic) then
        result = true
      end
    end
  -- 3. Demolition derby event in progress
  elseif gameplay_events_freeroam_demolitionDerby and rawget(gameplay_events_freeroam_demolitionDerby, 'eventActive') then
    result = true
  end

  if eventStatus ~= result then
    log('D', logTag, string.format('[Event] Event status has changed: %s -> %s', tostring(eventStatus), tostring(result)))
    eventStatus = result
  end
  return eventStatus
end

local function getActiveTarget()
  if isEventBlockingTraffic() then
    return 0
  end
  local setting = settings and settings.getValue and settings.getValue('trafficAmount')
  local val = tonumber(setting) or 0
  if val <= 0 and gameplay_traffic and gameplay_traffic.getIdealSpawnAmount then
    val = gameplay_traffic.getIdealSpawnAmount()
  end
  val = tonumber(val) or 6
  return math.max(0, math.floor(val))
end

local function getParkedTarget()
  if isEventBlockingTraffic() then
    return 0
  end
  local s = rawget(_G, 'overhaul_settings')
  if s and s.getSetting and s.getSetting('noParkedMode') then
    return 0
  end
  local setting = settings and settings.getValue and settings.getValue('trafficParkedAmount')
  local val = tonumber(setting) or 0
  if val <= 0 and gameplay_traffic and gameplay_traffic.getIdealSpawnAmount then
    val = gameplay_traffic.getIdealSpawnAmount(nil, true)
  end
  val = tonumber(val) or 14
  return math.max(0, math.floor(val))
end

local function getPlayerPos()
  local pid = be:getPlayerVehicleID(0)
  if pid and pid ~= -1 then
    local vehObj = getObjectByID(pid)
    if vehObj then
      playerPosVec:set(vehObj:getPosition())
      return playerPosVec
    end
  end

  local focus = gameplay_traffic and gameplay_traffic.getFocus()
  if focus and focus.pos then
    playerPosVec:set(focus.pos)
    return playerPosVec
  end

  if core_camera and core_camera.getPosition then
    local camPos = core_camera.getPosition()
    if camPos then
      playerPosVec:set(camPos)
      return playerPosVec
    end
  end

  return nil
end

-- ============================================================================
-- Vehicle Helper Functions
-- ============================================================================

local function isInDespawnArea(vehObj, playerPos)
  local vPos = vehObj:getPosition()
  local dx = vPos.x - playerPos.x
  local dy = vPos.y - playerPos.y
  return (dx * dx + dy * dy) > DESPAWN_DIST_SQ
end

local function isPlayerVehicle(vehId)
  if not vehId or vehId == -1 then return false end
  local pId = be:getPlayerVehicleID(0)
  if pId and pId ~= -1 and vehId == pId then return true end
  local obj = getObjectByID(vehId)
  if obj and obj:isPlayerControlled() then return true end
  return false
end

local function classifyVehicle(vehId)
  if not vehId or vehId == -1 or classifiedVehicles[vehId] then return end
  classifiedVehicles[vehId] = true

  local isPolice = false
  local isSpecial = false

  local tVeh = gameplay_traffic and gameplay_traffic.getTrafficData()[vehId]
  if tVeh then
    if tVeh.role and tVeh.role.name == 'police' then
      isPolice = true
      isSpecial = true
    elseif tVeh.isTaxi or tVeh.useRandomPaint == false then
      isSpecial = true
    end
  end

  local obj = getObjectByID(vehId)
  if obj and obj.partConfig then
    local pc = string.lower(obj.partConfig)
    if not isPolice then
      for _, kw in ipairs(POLICE_KEYWORDS) do
        if pc:find(kw, 1, true) then
          isPolice = true
          isSpecial = true
          break
        end
      end
    end
    if not isSpecial then
      for _, kw in ipairs(SPECIALIZED_KEYWORDS) do
        if pc:find(kw, 1, true) then
          isSpecial = true
          break
        end
      end
    end
  end

  if isPolice then policeVehicles[vehId] = true end
  if isSpecial then specializedVehicles[vehId] = true end
end

local function isPoliceVehicle(vehId)
  if not vehId then return false end
  if not classifiedVehicles[vehId] then classifyVehicle(vehId) end
  return policeVehicles[vehId] or false
end

local function isSpecializedVehicle(vehId)
  if not vehId then return false end
  if not classifiedVehicles[vehId] then classifyVehicle(vehId) end
  return specializedVehicles[vehId] or false
end

local function isPoliceInChase(vehId)
  if not isPoliceVehicle(vehId) then return false end
  if gameplay_police and gameplay_police.isVehicleInPursuit(vehId) then return true end
  
  local tVeh = gameplay_traffic and gameplay_traffic.getTrafficData()[vehId]
  if not tVeh or not tVeh.role then return false end
  
  return (tVeh.role.flags and tVeh.role.flags.pursuit == 1)
    or (tVeh.role.targetPursuitMode and tVeh.role.targetPursuitMode > 0)
    or (tVeh.role.state == 'chase' or tVeh.role.state == 'follow')
end

local function updatePoliceRespawnState(vehId, tVeh)
  local inChase = isPoliceInChase(vehId)
  if inChase then
    if tVeh and tVeh.state == 'active' then
      tVeh.enableRespawn = false
    end
  elseif tVeh and not tVeh.enableRespawn and isPoliceVehicle(vehId) then
    tVeh.enableRespawn = true
  end
  return inChase
end

local function retireVehicleObject(vehId, removeCallback)
  local vehObj = getObjectByID(vehId)
  if vehObj then
    local isSpecial = isSpecializedVehicle(vehId)
    if removeCallback then removeCallback(vehId) end
    vehObj:resetBrokenFlexMesh()
    vehObj:setActive(0)
    vehObj:setMeshAlpha(0, '')
    if not isSpecial then
      core_vehicle_manager.setVehiclePaintsNames(vehId, core_vehiclePaints.getRandomPaintsByVehicle(vehId))
    end
  end
  return vehObj
end

local function findInactiveCandidate(pool)
  for i, vehId in ipairs(pool) do
    local vehObj = getObjectByID(vehId)
    if vehObj then
      return vehId, i, vehObj
    end
  end
  return nil, nil, nil
end


-- ============================================================================
-- Drivable Traffic Circuit
-- ============================================================================

local function retireDrive(vehId, force)
  if not vehId or vehId == be:getPlayerVehicleID(0) then return false end
  if not force and isPoliceInChase(vehId) then return false end

  driveActivePool[vehId] = nil

  retireVehicleObject(vehId, gameplay_traffic and gameplay_traffic.removeTraffic)

  if not arrayFindValueIndex(driveInactivePool, vehId) then
    table.insert(driveInactivePool, vehId)
  end

  log('D', logTag, string.format('[Drive Pool / Retire] Retired traffic veh %d to inactive pool (active: %d, inactive: %d)',
    vehId, countKeys(driveActivePool), #driveInactivePool))
  return true
end

local function popToActiveDrive()
  if #driveInactivePool == 0 then return false end

  local candidateId, candidateIdx, vehObj = findInactiveCandidate(driveInactivePool)
  if not candidateId then return false end
  if not vehObj then
    table.remove(driveInactivePool, candidateIdx)
    return false
  end

  vehObj:setActive(1)
  local originPos = vehObj:getPosition()
  gameplay_traffic.insertTraffic(candidateId, false, true)
  gameplay_traffic.forceTeleport(candidateId, nil, nil, MIN_SPAWN_DIST, MAX_SPAWN_DIST)
  if vehObj:getPosition():squaredDistance(originPos) < 4 then
    -- Teleport failed to find a legal road node; rotate to back of queue
    gameplay_traffic.removeTraffic(candidateId)
    vehObj:setActive(0)
    table.remove(driveInactivePool, candidateIdx)
    table.insert(driveInactivePool, candidateId)
    return false
  end
  vehObj:setMeshAlpha(1, '')

  table.remove(driveInactivePool, candidateIdx)
  driveActivePool[candidateId] = true

  log('D', logTag, string.format('[Drive Pool / Activate] Popped veh %d from inactive to active traffic (active: %d, inactive: %d)',
    candidateId, countKeys(driveActivePool), #driveInactivePool))
  return candidateId
end


-- ============================================================================
-- Parked Car Circuit
-- ============================================================================

local function retireParked(vehId)
  if not vehId or vehId == be:getPlayerVehicleID(0) then return false end

  parkedActivePool[vehId] = nil

  retireVehicleObject(vehId, gameplay_parking and gameplay_parking.removeVehicle)

  if not arrayFindValueIndex(parkedInactivePool, vehId) then
    table.insert(parkedInactivePool, vehId)
  end

  log('D', logTag, string.format('[Parked Pool / Retire] Retired parked veh %d to inactive pool (active: %d, inactive: %d)',
    vehId, countKeys(parkedActivePool), #parkedInactivePool))
  return true
end

local function popToActiveParked(parkingSpot)
  if #parkedInactivePool == 0 or not parkingSpot then return false end

  local candidateId, candidateIdx, vehObj = findInactiveCandidate(parkedInactivePool)
  if not candidateId then return false end
  if not vehObj then
    table.remove(parkedInactivePool, candidateIdx)
    return false
  end

  table.remove(parkedInactivePool, candidateIdx)

  vehObj:setActive(1)
  gameplay_parking.insertVehicle(candidateId)
  gameplay_parking.moveToParkingSpot(candidateId, parkingSpot)
  vehObj:setMeshAlpha(1, '')

  parkedActivePool[candidateId] = true

  log('D', logTag, string.format('[Parked Pool / Activate] Popped veh %d from inactive to spot %s (active: %d, inactive: %d)',
    candidateId, tostring(parkingSpot.id), countKeys(parkedActivePool), #parkedInactivePool))
  return candidateId
end


-- ============================================================================
-- Registration and Spawn Handling
-- ============================================================================

local function registerTrafficVehicles(vehIds)
  if not vehIds or not vehIds[1] then return end
  local driveTarget = getActiveTarget()

  for _, vehId in ipairs(vehIds) do
    if not isPlayerVehicle(vehId) and getObjectByID(vehId) then
      classifyVehicle(vehId)
      if countKeys(driveActivePool) < driveTarget then
        driveActivePool[vehId] = true
      else
        retireDrive(vehId)
      end
    end
  end

  log('D', logTag, string.format('[Drive Pool / Register] Registered autoTraffic group: %d active / %d inactive (target: %d)',
    countKeys(driveActivePool), #driveInactivePool, driveTarget))
end

local function registerParkingVehicles(vehIds)
  if not vehIds or not vehIds[1] then return end
  local parkedTarget = getParkedTarget()

  for _, vehId in ipairs(vehIds) do
    if not isPlayerVehicle(vehId) and getObjectByID(vehId) then
      classifyVehicle(vehId)
      local vehObj = getObjectByID(vehId)
      if vehObj then
        vehObj:setDynDataFieldbyName("ignoreTraffic", 0, "true")
        vehObj:setDynDataFieldbyName("isParked", 0, "true")
        vehObj.playerUsable = false
        gameplay_walk.addVehicleToBlacklist(vehId)
      end

      if countKeys(parkedActivePool) < parkedTarget then
        parkedActivePool[vehId] = true
      else
        retireParked(vehId)
      end
    end
  end

  log('D', logTag, string.format('[Parked Pool / Register] Registered autoParking group: %d active / %d inactive (target: %d)',
    countKeys(parkedActivePool), #parkedInactivePool, parkedTarget))
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == "autoTraffic" then
    registerTrafficVehicles(vehList)
  elseif groupName == "autoParking" then
    registerParkingVehicles(vehList)
  end
end


-- ============================================================================
-- Update and Lifecycle
-- ============================================================================

local function captureDespawnedVehicles()
  local trafficData = gameplay_traffic and gameplay_traffic.getTrafficData()
  if trafficData then
    for vehId in pairs(driveActivePool) do
      local tVeh = trafficData[vehId]
      if tVeh and tVeh.state == 'queued' then
        retireDrive(vehId)
      end
    end
  end
end

local function onUpdate(dtReal, dtSim)
  captureTimer = captureTimer + dtSim
  if captureTimer >= CAPTURE_INTERVAL then
    captureTimer = 0
    captureDespawnedVehicles()
  end

  tickTimer = tickTimer + dtSim
  if tickTimer < TICK_INTERVAL then return end
  tickTimer = 0

  local playerPos = getPlayerPos()
  if not playerPos then return end

  local driveTarget = getActiveTarget()
  local parkedTarget = getParkedTarget()

  -- 1. Check active parked fleet for retirement
  table.clear(toRetireParked)
  for vehId in pairs(parkedActivePool) do
    local vehObj = getObjectByID(vehId)
    if not vehObj or parkedTarget == 0 or isInDespawnArea(vehObj, playerPos) then
      table.insert(toRetireParked, vehId)
    end
  end
  for _, vehId in ipairs(toRetireParked) do
    retireParked(vehId)
  end

  -- 2. Check active drive fleet for retirement & synchronize pursuing police
  local trafficData = gameplay_traffic and gameplay_traffic.getTrafficData()
  table.clear(toRetireDrive)
  for vehId in pairs(driveActivePool) do
    local vehObj = getObjectByID(vehId)
    if not vehObj then
      table.insert(toRetireDrive, vehId)
    else
      local tVeh = trafficData and trafficData[vehId]
      if not updatePoliceRespawnState(vehId, tVeh) then
        local hasTrailer = tVeh and tVeh.hasTrailer
        if driveTarget == 0 or (not hasTrailer and isInDespawnArea(vehObj, playerPos)) then
          table.insert(toRetireDrive, vehId)
        end
      end
    end
  end
  for _, vehId in ipairs(toRetireDrive) do
    retireDrive(vehId)
  end

  -- 3. Spawn 1 car per tick alternating: odd ticks active drive, even ticks parked
  if spawnDriveTick then
    local curDriveActive = countKeys(driveActivePool)
    if curDriveActive < driveTarget and #driveInactivePool > 0 then
      popToActiveDrive()
    end
  else
    local curParkedActive = countKeys(parkedActivePool)
    if curParkedActive < parkedTarget and #parkedInactivePool > 0 then
      local spots = gameplay_parking and gameplay_parking.getRandomParkingSpots(playerPos, MIN_SPAWN_DIST, MAX_SPAWN_DIST, 4, spotFilterOptions)
      if spots and spots[1] then
        for _, entry in ipairs(spots) do
          local ps = entry.ps
          if ps and not ps.vehicle then
            if popToActiveParked(ps) then
              break
            end
          end
        end
      end
    end
  end

  spawnDriveTick = not spawnDriveTick
end


-- ============================================================================
-- Hooks
-- ============================================================================

local function deactivateDrive()
  local playerVehId = be:getPlayerVehicleID(0)
  table.clear(toRetireDrive)
  for vehId in pairs(driveActivePool) do
    if vehId ~= playerVehId then
      table.insert(toRetireDrive, vehId)
    end
  end
  for _, vehId in ipairs(toRetireDrive) do
    retireDrive(vehId, true)
  end
end

local function deactivateParking()
  table.clear(toRetireParked)
  for vehId in pairs(parkedActivePool) do
    table.insert(toRetireParked, vehId)
  end
  for _, vehId in ipairs(toRetireParked) do
    retireParked(vehId)
  end
end

local function deactivateAllVehicles()
  deactivateDrive()
  deactivateParking()
end


local function onVehicleDestroyed(vehId)
  driveActivePool[vehId] = nil
  parkedActivePool[vehId] = nil
  classifiedVehicles[vehId] = nil
  policeVehicles[vehId] = nil
  specializedVehicles[vehId] = nil
  local dIdx = arrayFindValueIndex(driveInactivePool, vehId)
  if dIdx then table.remove(driveInactivePool, dIdx) end
  local pIdx = arrayFindValueIndex(parkedInactivePool, vehId)
  if pIdx then table.remove(parkedInactivePool, pIdx) end
end

local function resetAll()
  table.clear(driveActivePool)
  table.clear(driveInactivePool)
  table.clear(parkedActivePool)
  table.clear(parkedInactivePool)
  table.clear(classifiedVehicles)
  table.clear(policeVehicles)
  table.clear(specializedVehicles)
  spawnDriveTick = true
  tickTimer = 0
end

local function deleteDriveVehicles()
  local playerVehId = be:getPlayerVehicleID(0)
  for _, vehId in ipairs(driveInactivePool) do
    if vehId ~= playerVehId then
      local obj = getObjectByID(vehId)
      if obj then obj:delete() end
    end
  end
  table.clear(driveInactivePool)

  for vehId in pairs(driveActivePool) do
    if vehId ~= playerVehId then
      local obj = getObjectByID(vehId)
      if obj then obj:delete() end
    end
  end
  table.clear(driveActivePool)
  log('D', logTag, 'Deleted rotation pool drive fleet')
end

local function deleteParkedVehicles()
  local playerVehId = be:getPlayerVehicleID(0)
  for _, vehId in ipairs(parkedInactivePool) do
    if vehId ~= playerVehId then
      local obj = getObjectByID(vehId)
      if obj then obj:delete() end
    end
  end
  table.clear(parkedInactivePool)

  for vehId in pairs(parkedActivePool) do
    if vehId ~= playerVehId then
      local obj = getObjectByID(vehId)
      if obj then obj:delete() end
    end
  end
  table.clear(parkedActivePool)
  log('D', logTag, 'Deleted rotation pool parked fleet')
end

local function deleteAllVehicles()
  deleteDriveVehicles()
  deleteParkedVehicles()
  spawnDriveTick = true
  tickTimer = 0
end

local function wrapTrafficLifecycle()
  if gameplay_traffic and type(gameplay_traffic.deleteVehicles) == 'function' and not gameplay_traffic._rlsRotationDeleteWrapped then
    origDeleteVehicles = gameplay_traffic.deleteVehicles
    gameplay_traffic.deleteVehicles = function(...)
      deleteDriveVehicles()
      return origDeleteVehicles(...)
    end
    gameplay_traffic._rlsRotationDeleteWrapped = true
    log('D', logTag, 'Wrapped gameplay_traffic.deleteVehicles for rotation pool drive fleet cleanup')
  end

  if gameplay_traffic and type(gameplay_traffic.setActiveAmount) == 'function' and not gameplay_traffic._rlsRotationActiveAmountWrapped then
    origTrafficSetActiveAmount = gameplay_traffic.setActiveAmount
    gameplay_traffic.setActiveAmount = function(amount, ...)
      local res = origTrafficSetActiveAmount(amount, ...)
      if amount == 0 then
        deactivateDrive()
      end
      return res
    end
    gameplay_traffic._rlsRotationActiveAmountWrapped = true
    log('D', logTag, 'Wrapped gameplay_traffic.setActiveAmount for immediate drive fleet deactivation')
  end

  if gameplay_parking and type(gameplay_parking.setActiveAmount) == 'function' and not gameplay_parking._rlsRotationActiveAmountWrapped then
    origParkingSetActiveAmount = gameplay_parking.setActiveAmount
    gameplay_parking.setActiveAmount = function(amount, ...)
      local res = origParkingSetActiveAmount(amount, ...)
      if amount == 0 then
        deactivateParking()
      end
      return res
    end
    gameplay_parking._rlsRotationActiveAmountWrapped = true
    log('D', logTag, 'Wrapped gameplay_parking.setActiveAmount for immediate parked fleet deactivation')
  end
end

local function unwrapTrafficLifecycle()
  if origDeleteVehicles and gameplay_traffic then
    gameplay_traffic.deleteVehicles = origDeleteVehicles
    gameplay_traffic._rlsRotationDeleteWrapped = nil
    origDeleteVehicles = nil
  end
  if origTrafficSetActiveAmount and gameplay_traffic then
    gameplay_traffic.setActiveAmount = origTrafficSetActiveAmount
    gameplay_traffic._rlsRotationActiveAmountWrapped = nil
    origTrafficSetActiveAmount = nil
  end
  if origParkingSetActiveAmount and gameplay_parking then
    gameplay_parking.setActiveAmount = origParkingSetActiveAmount
    gameplay_parking._rlsRotationActiveAmountWrapped = nil
    origParkingSetActiveAmount = nil
  end
end

local function onExtensionLoaded()
  wrapTrafficLifecycle()
end

local function onExtensionUnloaded()
  unwrapTrafficLifecycle()
  deleteAllVehicles()
  resetAll()
end

M.getActiveTarget = getActiveTarget
M.getParkedTarget = getParkedTarget
M.getCounts = getCounts
M.getFleetReserveFloor = getFleetReserveFloor
M.getPoolSpawnAmount = getPoolSpawnAmount
M.getDespawnDist = getDespawnDist
M.getTotalCount = getTotalCount
M.retireDrive = retireDrive
M.retireParked = retireParked
M.popToActiveDrive = popToActiveDrive
M.popToActiveParked = popToActiveParked
M.deleteDriveVehicles = deleteDriveVehicles
M.deleteParkedVehicles = deleteParkedVehicles
M.deleteAllVehicles = deleteAllVehicles
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.deactivateDrive = deactivateDrive
M.deactivateParking = deactivateParking
M.deactivateAllVehicles = deactivateAllVehicles
M.resetAll = resetAll
M.onClientEndMission = resetAll
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onRaceBegin = deactivateAllVehicles
M.onUpdate = onUpdate

return M
