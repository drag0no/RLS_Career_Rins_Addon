local M = {}

M.dependencies = {"gameplay_walk"}

local cfg = {
  arrive = 0.42, approachTimeout = 14, stallWindow = 2, stallPath = 0.75,
  approachSpeedCoef = 0.45,
  boardDuration = 0.58, boardTimeout = 1.05,
  boardCollision = 0.35, boardStall = 1.05,
  entryCloseClearance = 0.28, entryPocketLength = 0.46,
  entryStepClearance = 0.31, entryStepArrive = 0.10, entryStepTimeout = 1.80,
  doorWaitClearance = 0.52, doorProbeInterval = 0.08,
  doorFallbackOpen = 0.16, doorSwingSettle = 0.28, doorOpenTimeout = 2.2,
  doorCloseDelay = 0.10, doorCloseFinish = 0.18,
  doorCloseTimeout = 1.65, doorCloseRetry = 0.90,
  driverSettleDuration = 0.68, boardLookRate = 4.25,
  boardLookMaxRate = math.rad(72), bodyClearance = 0.55,
  routeMargin = 0.58, waypointDistance = 0.24, obbMargin = 1,
  collisionHeightBelow = 0.55, collisionHeightAbove = 2.10, hullCacheTime = 0.08,
  standOutFraction = 0.32, standBackFraction = 0.38,
  lookRate = 2.15, lookPitchRate = 1.7,
  lookMaxRate = math.rad(48), lookMaxPitchRate = math.rad(28)
}
local up = vec3(0, 0, 1)

local approach = nil
local exitTransition = nil
local postEnter = nil
local postExit = nil
local driverSettle = nil
local lastApproachStats = nil
local lastExitStats = nil
local setWalkingCameraTransition
local prepareDriverSettle
local boardingCamera = {
  highSeatThreshold = 0.12,
  lowSeatThreshold = -0.12
}
local originalToggle = nil
local originalSetWalkingMode = nil
local originalSwitchCycle = nil
local collisionEnvelopes = {}
local collisionEnvelopeRequestId = 0
local lastPlayerPos = nil

-- last known unicycle move state from VE (speedCoef 0=walk, 1=sprint)
local lastSpeedCoef = 0
local lastWalkLen = 0
local lastExternal = {x = nil, y = nil, speed = nil}

local function isRealisticEntryEnabled()
  local s = rawget(_G, "overhaul_settings")
  if s and s.getSetting then
    return s.getSetting("realisticVehicleEntry") ~= false
  end
  return true
end

local function isEnterableVehicle(veh)
  if not veh or veh.playerUsable == false or veh:getJBeamFilename() == "unicycle" then
    return false
  end
  if gameplay_walk.isVehicleBlacklisted and gameplay_walk.isVehicleBlacklisted(veh:getId()) then
    return false
  end
  return veh:getActive() == true or veh:getActive() == 1
end

local function vecToTable(v)
  return v and {x = v.x, y = v.y, z = v.z} or nil
end

local function angleDeg(a, b)
  if not a or not b then return nil end
  return math.deg(math.acos(clamp(a:dot(b), -1, 1)))
end

local function clearExternalMove(unicycle)
  if not unicycle then return end
  lastExternal.x, lastExternal.y, lastExternal.speed = nil, nil, nil
  unicycle:queueLuaCommand("controller.getControllerSafe('playerController').setExternalWorldMove(nil)")
end

local function setExternalMove(unicycle, x, y, speedCoef)
  if not unicycle then return end
  if lastExternal.x == x and lastExternal.y == y and lastExternal.speed == speedCoef then
    return
  end
  lastExternal.x, lastExternal.y, lastExternal.speed = x, y, speedCoef
  unicycle:queueLuaCommand(string.format(
    "controller.getControllerSafe('playerController').setExternalWorldMove(%s,%s,%s)",
    tostring(x), tostring(y), tostring(speedCoef)
  ))
end

local function notePlayerMove(speedCoef, walkLen)
  lastSpeedCoef = tonumber(speedCoef) or 0
  lastWalkLen = tonumber(walkLen) or 0
end

local function smoothstep01(t)
  t = clamp(t or 0, 0, 1)
  return t * t * (3 - 2 * t)
end

local function getVehicleData(veh)
  return veh and core_vehicle_manager.getVehicleData(veh:getId()) or nil
end

-- TriggerObject:getCenter() can retain coordinates from the previously spawned
-- vehicle. Rebuild the trigger transform from its live JBeam reference nodes;
-- idRef is the latch end and idX points toward the hinge on stock door triggers.
local function getTriggerNodeGeometry(veh, triggerData)
  if not veh or not triggerData or triggerData.idRef == nil then return nil end
  local refNode = veh:getNodePosition(triggerData.idRef)
  if not refNode then return nil end
  local ref = veh:getPosition() + refNode
  local center = vec3(ref)
  local hingeNodeId = triggerData.idX
  local hinge, hingeLongSign, doorSpan

  local xNode = hingeNodeId ~= nil and veh:getNodePosition(hingeNodeId) or nil
  local yNode = triggerData.idY ~= nil and veh:getNodePosition(triggerData.idY) or nil
  if xNode then
    hinge = veh:getPosition() + xNode
    local xAxis = hinge - ref
    doorSpan = xAxis:length()
    if doorSpan > 1e-4 then
      xAxis:setScaled(1 / doorSpan)
      local fwd = veh:getDirectionVector():z0()
      if fwd:length() > 1e-4 then
        fwd:normalize()
        local along = (hinge - ref):z0():dot(fwd)
        if math.abs(along) > 0.05 then hingeLongSign = along > 0 and 1 or -1 end
      end

      if yNode then
        local yRaw = (veh:getPosition() + yNode) - ref
        if yRaw:length() > 1e-4 then
          yRaw:normalize()
          local zAxis = xAxis:cross(yRaw)
          if zAxis:length() > 1e-4 then
            zAxis:normalize()
            local yAxis = zAxis:cross(xAxis)
            yAxis:normalize()
            local base = triggerData.baseTranslation or {}
            local translation = triggerData.translation or {}
            center = ref
              + xAxis * ((tonumber(base.x) or 0) + (tonumber(translation.x) or 0))
              + yAxis * ((tonumber(base.y) or 0) + (tonumber(translation.y) or 0))
              + zAxis * ((tonumber(base.z) or 0) + (tonumber(translation.z) or 0))
          end
        end
      end
    end
  end
  return center, hingeLongSign, doorSpan, hingeNodeId, ref
end

local function getUsableTriggerCenter(veh, triggerObj)
  if not veh or not triggerObj then return nil end
  local center = triggerObj:getCenter()
  if not center then return nil end
  local vehId = veh:getId()
  if be:getObjectOOBBIsInitialized(vehId) then
    local obbCenter = vec3(be:getObjectOOBBCenterXYZ(vehId))
    local extent = 0
    for i = 0, 2 do
      extent = extent + vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i)):length()
    end
    if center:distance(obbCenter) > extent * 1.8 + 2 then
      return nil
    end
  end
  return center
end

local function getDoorTriggerInfo(veh, doorName)
  local vData = getVehicleData(veh)
  local triggers = vData and vData.vdata and vData.vdata.triggers
  if type(triggers) ~= "table" then return nil end
  for _, trg in pairs(triggers) do
    if trg.name == doorName then
      local cid = trg.cid or trg.abid
      local obj = cid ~= nil and veh:getTrigger(cid) or nil
      local center = getTriggerNodeGeometry(veh, trg)
      if not center and obj then center = getUsableTriggerCenter(veh, obj) end
      if center then return center, cid, vData, trg end
    end
  end
  return nil
end

local function getDoorTriggerCenter(veh, doorName)
  local center = getDoorTriggerInfo(veh, doorName)
  return center
end

local function getVehicleLeft2D(veh)
  if not veh then return nil end
  local fwd = veh:getDirectionVector():z0()
  if fwd:length() < 1e-4 then return nil end
  fwd:normalize()
  local left = veh:getDirectionVectorUp():cross(fwd):z0()
  if left:length() < 1e-4 then return nil end
  left:normalize()
  return left
end

local function getLateralOffset(veh, point)
  local left = getVehicleLeft2D(veh)
  if not left or not point then return nil end
  return (point - veh:getPosition()):z0():dot(left)
end

local function getLongitudinalOffset(veh, point)
  if not veh or not point then return nil end
  local fwd = veh:getDirectionVector():z0()
  if fwd:length() < 1e-4 then return nil end
  fwd:normalize()
  return (point - veh:getPosition()):z0():dot(fwd)
end

local function getVehicleHalfWidth2D(veh)
  local left = getVehicleLeft2D(veh)
  if not left then return nil end
  local vehId = veh:getId()
  if not be:getObjectOOBBIsInitialized(vehId) then return nil end
  local extent = 0
  for i = 0, 2 do
    extent = extent + math.abs(vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i)):dot(left))
  end
  return extent
end

local function getVehicleBasis(veh)
  if not veh then return nil end
  local fwd = veh:getDirectionVector()
  local bodyUp = veh:getDirectionVectorUp()
  if fwd:length() < 1e-4 or bodyUp:length() < 1e-4 then return nil end
  fwd:normalize()
  bodyUp:normalize()
  local left = bodyUp:cross(fwd)
  if left:length() < 1e-4 then return nil end
  left:normalize()
  local correctedUp = fwd:cross(left)
  correctedUp:normalize()
  return left, fwd, correctedUp
end

local function worldPointToVehicleLocal(veh, point)
  local left, fwd, bodyUp = getVehicleBasis(veh)
  if not left or not point then return nil end
  local offset = point - veh:getPosition()
  return vec3(offset:dot(left), offset:dot(fwd), offset:dot(bodyUp))
end

local function vehicleLocalPointToWorld(veh, point)
  local left, fwd, bodyUp = getVehicleBasis(veh)
  if not left or not point then return nil end
  return veh:getPosition() + left * point.x + fwd * point.y + bodyUp * point.z
end

local function getDoorSideSign(side)
  return side == "R" and -1 or 1
end

local function isDoorCenterOnSide(veh, center, side)
  local lateral = getLateralOffset(veh, center)
  if lateral == nil then return false, lateral end
  return lateral * getDoorSideSign(side) > 0.04, lateral
end

-- Trigger objects can survive a door close with a stale/default center. Keep the
-- named trigger/controller for actuation, but never use wrong-side geometry for
-- walking. The driver camera node supplies the doorway's longitudinal location;
-- the OOBB supplies only a conservative outer side when the trigger is unusable.
local function synthesizeDriverDoorCenter(veh, side, driverWorldPos, driverLateral)
  local left, fwd, bodyUp = getVehicleBasis(veh)
  if not left then return nil end

  local vehPos = veh:getPosition()
  local sign = getDoorSideSign(side)
  local driverLocal = driverWorldPos and worldPointToVehicleLocal(veh, driverWorldPos) or nil
  local targetLong = driverLocal and driverLocal.y or 0
  local targetUp = driverLocal and (driverLocal.z - 0.35) or 0.65
  local targetLateral = math.abs(driverLateral or 0) + 0.30

  local vehId = veh:getId()
  if be:getObjectOOBBIsInitialized(vehId) then
    local obbCenter = vec3(be:getObjectOOBBCenterXYZ(vehId))
    local centerLocal = worldPointToVehicleLocal(veh, obbCenter)
    local sideExtent = 0
    for i = 0, 2 do
      sideExtent = sideExtent + math.abs(vec3(be:getObjectOOBBHalfAxisXYZ(vehId, i)):dot(left))
    end
    local sideBoundary = math.abs((centerLocal and centerLocal.x or 0) + sign * sideExtent)
    -- Mirrors and attachments may widen the OOBB well beyond the front door.
    -- Cap that contribution relative to the physical seat position.
    local driverBase = math.abs(driverLateral or 0)
    targetLateral = math.max(targetLateral, math.min(sideBoundary, driverBase + 0.55))
  end

  targetLateral = math.max(targetLateral, 0.45)
  return vehPos + left * (sign * targetLateral) + fwd * targetLong + bodyUp * targetUp
end

local function isDoorReferenceGeometryValid(veh, center, side, driverWorldPos, driverLateral)
  local onSide, lateral = isDoorCenterOnSide(veh, center, side)
  if not onSide then return false, lateral end

  local fallback = synthesizeDriverDoorCenter(veh, side, driverWorldPos, driverLateral)
  local rawLocal = worldPointToVehicleLocal(veh, center)
  local fallbackLocal = fallback and worldPointToVehicleLocal(veh, fallback) or nil
  if rawLocal and fallbackLocal then
    -- A trigger left at the swung panel can still have the correct sign while
    -- being much too far from the closed body to use as a walking doorway.
    if math.abs(rawLocal.x) > math.abs(fallbackLocal.x) + 0.28 then
      return false, lateral
    end
    if math.abs(rawLocal.y - fallbackLocal.y) > 1.25 then
      return false, lateral
    end
  end
  return true, lateral
end

local function scoreFrontDoorName(rawName, side, isController)
  local n = tostring(rawName or ""):lower()
  if n == "" or n:find("_int", 1, true) or n:find("rear", 1, true)
    or n:find("sleeper", 1, true) or n:find("barndoor", 1, true)
    or n:find("tailgate", 1, true) or n:find("engine", 1, true) then
    return nil
  end
  if isController and not n:find("coupler", 1, true) then return nil end

  local compact = n:gsub("[^a-z0-9]", "")
  local wanted = side == "R" and "r" or "l"
  local other = side == "R" and "l" or "r"
  local score
  if compact:find("doorf" .. wanted, 1, true) == 1 then
    score = 140
  elseif compact:find("doorfront" .. wanted, 1, true) == 1 then
    score = 135
  elseif compact:find("door" .. wanted .. "f", 1, true) == 1 then
    score = 130
  elseif compact:find("door" .. wanted, 1, true) == 1 then
    score = 110
  end
  if not score or compact:find("doorf" .. other, 1, true) == 1
    or compact:find("doorfront" .. other, 1, true) == 1 then
    return nil
  end
  if compact:find("doorrr", 1, true) == 1 or compact:find("doorrl", 1, true) == 1 then
    return nil
  end
  if isController and n:find("advanced", 1, true) then score = score + 2 end
  return score
end

local function findDriverDoorInfo(veh)
  if not veh then return nil end
  local driverNodeId, rightHandDrive, rightHandDoor = core_camera.getDriverData(veh)
  local driverWorldPos
  local driverLateral
  if driverNodeId ~= nil then
    local nodePos = veh:getNodePosition(driverNodeId)
    if nodePos then
      driverWorldPos = veh:getPosition() + nodePos
      driverLateral = getLateralOffset(veh, driverWorldPos)
    end
  end
  -- Scale confidence by body width. A fixed threshold misclassifies narrow,
  -- center-seat/RHD vehicles such as the Pigeon.
  local halfWidth = getVehicleHalfWidth2D(veh)
  local driverSideThreshold = math.max(0.04, (halfWidth or 0.45) * 0.18)
  local driverNodeDefinesSide = driverLateral
    and math.abs(driverLateral) > driverSideThreshold
  local side = driverNodeDefinesSide
    and (driverLateral < 0 and "R" or "L")
    or (rightHandDoor and "R" or "L")
  local canonicalName = "door_" .. side
  local vData = getVehicleData(veh)
  local vdata = vData and vData.vdata or nil

  local triggerName, triggerCenter, triggerScore = nil, nil, -math.huge
  local hingeLongSign, doorSpan, hingeNodeId, triggerReferencePoint
  for _, trg in pairs(vdata and vdata.triggers or {}) do
    local score = scoreFrontDoorName(trg.name, side, false)
    if score and score > triggerScore then
      local cid = trg.cid or trg.abid
      local obj = cid ~= nil and veh:getTrigger(cid) or nil
      local nodeCenter, nodeHingeLongSign, nodeDoorSpan, nodeHingeId, nodeRef =
        getTriggerNodeGeometry(veh, trg)
      if nodeCenter or obj then
        triggerName = trg.name
        triggerCenter = nodeCenter or getUsableTriggerCenter(veh, obj)
        hingeLongSign = nodeHingeLongSign
        doorSpan = nodeDoorSpan
        hingeNodeId = nodeHingeId
        triggerReferencePoint = nodeRef
        triggerScore = score
      end
    end
  end

  local controllerName, controllerScore = nil, -math.huge
  for _, ctrl in pairs(vdata and vdata.controller or {}) do
    if ctrl.fileName == "advancedCouplerControl" then
      local score = scoreFrontDoorName(ctrl.name, side, true)
      if score and score > controllerScore then
        controllerName = ctrl.name
        controllerScore = score
      end
    end
  end

  local triggerCenterValid, triggerLateral = isDoorReferenceGeometryValid(
    veh, triggerCenter, side, driverWorldPos, driverLateral
  )
  local referenceCenter = triggerCenterValid and vec3(triggerCenter)
    or synthesizeDriverDoorCenter(veh, side, driverWorldPos, driverLateral)
  if not referenceCenter and triggerCenter then referenceCenter = vec3(triggerCenter) end
  local referenceLocal = referenceCenter and worldPointToVehicleLocal(veh, referenceCenter) or nil
  local safeStandLongSign = hingeLongSign and -hingeLongSign or -1
  -- The Nine's front trigger X axis is reversed relative to its usable standing
  -- pocket. Its front-left door must be approached behind the panel even though
  -- the generic trigger-axis heuristic classifies it like the Piccolina.
  if veh:getJBeamFilename() == "nine" and triggerName == "door_FL" then
    safeStandLongSign = -1
  end

  return {
    side = side,
    driverNodeId = driverNodeId,
    driverWorldPos = driverWorldPos,
    driverLateral = driverLateral,
    driverHalfWidth = halfWidth,
    driverSideThreshold = driverSideThreshold,
    sideSource = driverNodeDefinesSide and "driverNode" or "cameraMetadata",
    rightHandDrive = rightHandDrive == true,
    rightHandDoor = rightHandDoor == true,
    canonicalName = canonicalName,
    triggerName = triggerName,
    controllerName = controllerName,
    triggerCenter = triggerCenter,
    triggerCenterValid = triggerCenterValid == true,
    triggerLateral = triggerLateral,
    triggerReferencePoint = triggerReferencePoint,
    hingeLongSign = hingeLongSign,
    safeStandLongSign = safeStandLongSign,
    doorSpan = doorSpan,
    hingeNodeId = hingeNodeId,
    center = referenceCenter,
    referenceLocal = referenceLocal,
    referenceSource = triggerCenterValid and "triggerNodes" or "driverNodeFallback"
  }
end

local function getDriverDoorSideAlignment(veh, playerPos, doorInfo, doorCenter)
  if not veh or not playerPos then return nil end
  local playerLateral = getLateralOffset(veh, playerPos)
  local driverLateral = doorInfo and doorInfo.sideSource == "driverNode"
    and doorInfo.driverLateral or nil
  local doorLateral = getLateralOffset(veh, doorCenter)
  local expectedLateral = driverLateral
  if not expectedLateral or math.abs(expectedLateral) <= 0.08 then
    expectedLateral = doorLateral
  end
  if (not expectedLateral or math.abs(expectedLateral) <= 0.08) and doorInfo then
    expectedLateral = doorInfo.side == "R" and -1 or 1
  end
  if playerLateral == nil or expectedLateral == nil then
    return nil, playerLateral, expectedLateral, doorLateral
  end
  local playerAligned = playerLateral * expectedLateral > 0.04
  local doorAligned = doorLateral ~= nil and doorLateral * expectedLateral > 0.04
  return playerAligned and doorAligned,
    playerLateral, expectedLateral, doorLateral
end

local function copyStateFields(target, source, keys, mode)
  for key in string.gmatch(keys, "%S+") do
    local value = source[key]
    if mode == "bool" then value = value == true end
    if mode == "zero" then value = value or 0 end
    target[key] = value
  end
end

local function copyDoorStats(stats, state)
  if not stats or not state then return end
  copyStateFields(stats, state, [[doorStateAfter doorOpenStateAfter doorCloseStateAfter
    doorGap doorOpenForceDuration doorCloseForceDuration doorFullEvidence]])
  copyStateFields(stats, state, [[doorControllerFound doorOpened doorClosed
    doorPhysicalMeasured doorFullyOpened doorOpenTimedOut]], "bool")
  copyStateFields(stats, state, "maxDoorGap doorStableProbes", "zero")
  stats.doorOpenWait = state.doorOpenWait or state.doorOpenElapsed or 0
  stats.doorCloseAttempts = (state.closeRetryCount or 0) + (state.closeCommanded and 1 or 0)
end

local function markDoorFullyOpen(state, evidence)
  if not state or state.doorFullyOpened then return end
  state.doorFullyOpened = true
  state.doorOpenReady = true
  state.doorFullEvidence = evidence
  state.doorOpenWait = state.doorOpenElapsed or 0
  state.doorFullyOpenT = state.t or 0
end

local function isDoorOpenReady(state)
  if not state then return true end
  if state.doorOpenReady or state.doorFullyOpened then return true end
  local elapsed = state.doorOpenElapsed or 0
  local controllerName = state.doorControllerName or state.controllerName
  if not controllerName then
    if elapsed >= cfg.doorFallbackOpen then
      state.doorOpenReady = true
      state.doorFullEvidence = "noController"
      state.doorOpenWait = elapsed
    end
    return state.doorOpenReady == true
  end
  if state.doorControllerFound == false and (state.doorProbeCount or 0) > 0 then
    if elapsed >= cfg.doorFallbackOpen then
      state.doorOpenReady = true
      state.doorFullEvidence = "controllerUnavailable"
      state.doorOpenWait = elapsed
    end
    return state.doorOpenReady == true
  end

  local forceDuration = math.max(state.doorOpenForceDuration or 0.20, 0.08)
  if state.doorPhysicalMeasured then
    local gap = state.doorGap or 0
    local stable = state.doorStableProbes or 0
    if gap >= 0.08 and elapsed >= math.max(0.36, forceDuration + 0.08) and stable >= 2 then
      markDoorFullyOpen(state, "physicalSettle")
    elseif math.max(gap, state.maxDoorGap or 0) >= 0.08
      and elapsed >= math.max(0.72, forceDuration + 0.30) then
      -- Bounded fallback for doors that keep gently oscillating at their stop.
      -- Scissor-door latch pairs can have only ~0.15 m of separation even when
      -- the panel is fully raised, so long-settled physical motion is stronger
      -- evidence than a one-size-fits-all gap magnitude.
      markDoorFullyOpen(state, "physicalGapAndLongSettle")
    end
  elseif state.doorControllerFound == true then
    -- A handful of legacy controllers do not expose their coupler node pair.
    -- Their own configured force duration is still a better full-swing gate than
    -- treating the first detached latch state as an open door.
    if elapsed >= math.max(0.52, forceDuration + cfg.doorSwingSettle) then
      markDoorFullyOpen(state, "configuredDuration")
    end
  end

  local hardLimit = math.max(cfg.doorOpenTimeout, forceDuration + 1.0)
  if not state.doorOpenReady and elapsed >= hardLimit then
    state.doorOpenTimedOut = true
    state.doorOpenReady = true
    state.doorOpenWait = elapsed
    state.doorFullEvidence = "hardLimit"
  end
  return state.doorOpenReady == true
end

local function getDoorCloseRetryInterval(state)
  return math.max(
    cfg.doorCloseRetry,
    (state and state.doorCloseForceDuration or 0.6) + 0.25
  )
end

local function noteDoorState(vehId, transitionType, controllerName, wantOpen, found, beforeState, afterState, gap, openForceDuration, closeForceDuration)
  local state = transitionType == "exit" and (exitTransition or postExit) or (approach or postEnter)
  if not state or state.vehId ~= vehId then return end
  state.doorControllerFound = found == true
  state.doorStateBefore = state.doorStateBefore or beforeState
  state.doorStateAfter = afterState
  local duration = tonumber(openForceDuration)
  if duration and duration >= 0 then state.doorOpenForceDuration = duration end
  local closeDuration = tonumber(closeForceDuration)
  if closeDuration and closeDuration >= 0 then state.doorCloseForceDuration = closeDuration end
  local physicalGap = tonumber(gap)
  if physicalGap and physicalGap >= 0 then
    state.doorPhysicalMeasured = true
    state.doorGap = physicalGap
    state.maxDoorGap = math.max(state.maxDoorGap or 0, physicalGap)
    if wantOpen then
      local previous = state.previousDoorGap
      local tolerance = math.max(0.018, physicalGap * 0.018)
      if previous and math.abs(physicalGap - previous) <= tolerance then
        state.doorStableProbes = (state.doorStableProbes or 0) + 1
      else
        state.doorStableProbes = 0
      end
      state.previousDoorGap = physicalGap
    end
  end
  if wantOpen then
    state.doorOpenStateAfter = afterState
  else
    state.doorCloseStateAfter = afterState
  end
  state.doorOpened = wantOpen and found == true
    and afterState ~= "attached" and afterState ~= "desyncedAttached"
    or state.doorOpened
  state.doorClosed = (not wantOpen) and found == true
    and (afterState == "attached" or afterState == "desyncedAttached")
    or state.doorClosed
  if wantOpen then isDoorOpenReady(state) end
  if state == postEnter and lastApproachStats then
    copyDoorStats(lastApproachStats, state)
  end
  if state == postExit and lastExitStats then
    copyDoorStats(lastExitStats, state)
  end
end

-- wantOpen true = open if closed; false = close if open (uses door coupler state)
local function ensureDoorState(veh, controllerName, wantOpen, transitionType, probeOnly)
  if not veh or not controllerName then return false end
  local callback = string.format(
    "if overhaul_walkEnterVehicle then overhaul_walkEnterVehicle.noteDoorState(%d,%s,%s,%s,%%s,%%s,%%s,%%s,%%s,%%s) end",
    veh:getId(), serialize(transitionType or "entry"), serialize(controllerName), wantOpen and "true" or "false"
  )
  veh:queueLuaCommand(string.format([[
    local c = controller.getControllerSafe(%s)
    local wantOpen = %s
    local probeOnly = %s
    local cfg = v.data and v.data[%s] or nil
    if not cfg and v.data and v.data.controller then
      for _, row in pairs(v.data.controller) do
        if type(row) == "table" and row.name == %s then cfg = row break end
      end
    end
    local closeForce = cfg and tonumber(cfg.closeForceMagnitude) or 0
    local closeDuration = cfg and tonumber(cfg.closeForceDuration) or 0
    local gentleClose = closeForce > 0 and closeForce <= 60 and closeDuration >= 0.6
    local found = c ~= nil and c.getGroupState ~= nil
    local before = found and c.getGroupState() or nil
    if found and not probeOnly then
      local closed = (before == "attached" or before == "desyncedAttached")
      if wantOpen then
        if closed and c.detachGroup then c.detachGroup() end
      else
        if not closed and not gentleClose and c.tryAttachGroupImpulse then c.tryAttachGroupImpulse() end
      end
    end
    local after = found and c.getGroupState() or nil
    local duration = cfg and tonumber(cfg.openForceDuration) or -1
    local maxGap = -1
    if cfg and type(cfg.couplerNodes) == "table" and beamstate and beamstate.nodeNameMap then
      local rows = tableFromHeaderTable(cfg.couplerNodes)
      for _, row in ipairs(rows or {}) do
        local cid1 = beamstate.nodeNameMap[row.cid1] or tonumber(row.cid1)
        local cid2 = beamstate.nodeNameMap[row.cid2] or tonumber(row.cid2)
        if cid1 and cid2 then
          local nodeGap = obj:nodeLength(cid1, cid2)
          if nodeGap and nodeGap > maxGap then maxGap = nodeGap end
          if not wantOpen and found and after ~= "broken" and gentleClose then
            -- Long-duration, light-force doors can damage their latch when a
            -- full fixed impulse starts at the open stop. Register the stock
            -- latch once, then servo the panel inward: useful force while far
            -- away, gently tapered force through the final centimetres.
            if not probeOnly then
              obj:attachLocalCoupler(
                cid1, cid2,
                tonumber(row.autoCouplingStrength) or 35000,
                tonumber(row.autoCouplingRadius) or 0.01,
                tonumber(row.autoCouplingLockRadius) or 0.005,
                tonumber(row.autoCouplingSpeed) or 0.2,
                true
              )
            end
            local maxScale = closeDuration >= 1.0 and 0.80 or 0.55
            local gapRatio = math.min(math.max((nodeGap - 0.01) / 0.40, 0), 1)
            local forceScale = 0.16 + (maxScale - 0.16) * gapRatio
            obj:applyForceTime(cid2, cid1, closeForce * forceScale, 0.10)
          elseif not wantOpen and not probeOnly and found and after ~= "broken"
            and nodeGap and nodeGap <= 0.025 and closeForce >= 75 then
            -- A few heavy four-door panels can stop millimetres outside their
            -- tiny stock latch radius. Keep all movement physical, but let a
            -- near-closed door catch at 2.5 cm instead of oscillating forever.
            obj:attachLocalCoupler(
              cid1, cid2,
              tonumber(row.autoCouplingStrength) or 35000,
              math.max(tonumber(row.autoCouplingRadius) or 0.01, 0.025),
              tonumber(row.autoCouplingLockRadius) or 0.005,
              tonumber(row.autoCouplingSpeed) or 0.2,
              true
            )
          end
        end
      end
    end
    obj:queueGameEngineLua(string.format(%s, tostring(found), serialize(before), serialize(after), tostring(maxGap), tostring(duration), tostring(closeDuration)))
  ]], serialize(controllerName), wantOpen and "true" or "false", probeOnly and "true" or "false",
    serialize(controllerName), serialize(controllerName), serialize(callback)))
  return true
end

local function holdEntryDoorOpen(veh, dt)
  approach.entryDoorHoldT = (approach.entryDoorHoldT or 0) + dt
  if approach.doorControllerName
    and approach.entryDoorHoldT >= cfg.doorProbeInterval then
    approach.entryDoorHoldT = 0
    ensureDoorState(veh, approach.doorControllerName, true, "entry")
    approach.doorProbeCount = (approach.doorProbeCount or 0) + 1
  end
end

-- Kept as the public compatibility name, but realistic entry always targets the driver door.
local function getClosestDoorName(veh, fromPos)
  local info = findDriverDoorInfo(veh)
  if not info then return nil end
  return info.triggerName or info.canonicalName, info.center, info
end

local function getVehicleOBB(vehId)
  if not be:getObjectOOBBIsInitialized(vehId) then return nil end
  local center = vec3()
  local axis0 = vec3()
  local axis1 = vec3()
  local axis2 = vec3()
  center:set(be:getObjectOOBBCenterXYZ(vehId))
  axis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  axis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  axis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
  return center, axis0, axis1, axis2
end

-- vehicle object ref (origin); look uses cabin height from OBB
local function getVehicleRefPos(veh)
  return veh:getPosition()
end

local function getVehicleLookPos(veh)
  local ref = getVehicleRefPos(veh)
  local center = getVehicleOBB(veh:getId())
  if center then
    return vec3(ref.x, ref.y, center.z)
  end
  return ref + vec3(0, 0, 1.0)
end

-- blend door->vehicle; from behind bias deeper into the car
local function getBoardTarget(veh, doorRef, aftFactor)
  local vehRef = getVehicleRefPos(veh)
  if not vehRef then return nil end
  if not doorRef then return vec3(vehRef) end
  local t = 0.5 + 0.25 * clamp(aftFactor or 0, 0, 1)
  return doorRef + (vehRef - doorRef) * t
end

local function getBoardLookPos(veh, doorRef, aftFactor)
  local mid = getBoardTarget(veh, doorRef, aftFactor)
  if not mid then return nil end
  local center = getVehicleOBB(veh:getId())
  if center then
    return vec3(mid.x, mid.y, center.z)
  end
  return mid + vec3(0, 0, 1.0)
end

-- live door center so the camera can track the panel while it opens
local function getDoorLookPos(veh, doorCenter)
  if not doorCenter then return nil end
  local center = getVehicleOBB(veh:getId())
  if center then
    -- Aim at the window/upper-door region rather than a low latch node. At
    -- walking eye height this keeps the panel and cabin in frame.
    return vec3(doorCenter.x, doorCenter.y, center.z + 0.55)
  end
  return doorCenter + vec3(0, 0, 1.0)
end

-- Keep the opened door dominant while retaining enough of the body in frame to
-- make the exit direction readable. Raw trigger centers can sit low at a latch.
local function getExitDoorLookPos(veh, doorCenter)
  local doorLook = getDoorLookPos(veh, doorCenter)
  local vehLook = getVehicleLookPos(veh)
  if doorLook and vehLook then
    local target = doorLook * 0.45 + vehLook * 0.55
    target.z = doorLook.z
    return target
  end
  return doorLook or vehLook
end

local function getOBBBasis2D(center, axis0, axis1, margin)
  local c2 = center:z0()
  local u0 = axis0:z0()
  local u1 = axis1:z0()
  local len0 = u0:length()
  local len1 = u1:length()
  if len0 < 1e-4 or len1 < 1e-4 then return nil end
  u0:setScaled(1 / len0)
  u1:setScaled(1 / len1)
  return c2, u0, u1, len0 + (margin or 0), len1 + (margin or 0)
end

local function localOBBCoords(p, c2, u0, u1)
  local d = p:z0() - c2
  return d:dot(u0), d:dot(u1)
end

-- signed clearance outside expanded OBB (negative = inside)
local function obbClearance2D(p, center, axis0, axis1, margin)
  local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, margin)
  if not c2 then return math.huge end
  local x, y = localOBBCoords(p, c2, u0, u1)
  local dx = math.abs(x) - e0
  local dy = math.abs(y) - e1
  if dx > 0 or dy > 0 then
    local outsideX = math.max(dx, 0)
    local outsideY = math.max(dy, 0)
    return math.sqrt(outsideX * outsideX + outsideY * outsideY)
  end
  return math.max(dx, dy)
end

local function pushOutsideOBB2D(p, center, axis0, axis1, margin)
  local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, margin)
  if not c2 then return p:z0() end
  local x, y = localOBBCoords(p, c2, u0, u1)
  if math.abs(x) > e0 or math.abs(y) > e1 then
    return vec3(p.x, p.y, p.z)
  end
  -- push out along the nearest face
  local pushX = (e0 - math.abs(x)) + 0.05
  local pushY = (e1 - math.abs(y)) + 0.05
  local out
  if pushX < pushY then
    out = c2 + u0 * ((x >= 0 and 1 or -1) * e0) + u1 * y
  else
    out = c2 + u0 * x + u1 * ((y >= 0 and 1 or -1) * e1)
  end
  return vec3(out.x, out.y, p.z)
end

local function cross2D(a, b, c)
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function convexHull2D(points)
  if #points < 3 then return nil end
  table.sort(points, function(a, b)
    return a.x < b.x or (a.x == b.x and a.y < b.y)
  end)

  local unique = {}
  local lastX, lastY
  for _, point in ipairs(points) do
    if not lastX or math.abs(point.x - lastX) > 0.005 or math.abs(point.y - lastY) > 0.005 then
      unique[#unique + 1] = point
      lastX, lastY = point.x, point.y
    end
  end
  if #unique < 3 then return nil end

  local lower = {}
  for _, point in ipairs(unique) do
    while #lower >= 2 and cross2D(lower[#lower - 1], lower[#lower], point) <= 1e-7 do
      lower[#lower] = nil
    end
    lower[#lower + 1] = point
  end

  local upper = {}
  for i = #unique, 1, -1 do
    local point = unique[i]
    while #upper >= 2 and cross2D(upper[#upper - 1], upper[#upper], point) <= 1e-7 do
      upper[#upper] = nil
    end
    upper[#upper + 1] = point
  end

  lower[#lower] = nil
  upper[#upper] = nil
  for _, point in ipairs(upper) do lower[#lower + 1] = point end
  return #lower >= 3 and lower or nil
end

local function getCollisionHull(vehId, pathZ)
  local envelope = collisionEnvelopes[vehId]
  if not envelope or type(envelope.nodeIds) ~= "table" or #envelope.nodeIds < 3 then
    return nil, envelope
  end
  pathZ = tonumber(pathZ) or 0
  local now = os.clock()
  if envelope.hull and envelope.hullZ
    and math.abs(envelope.hullZ - pathZ) < 0.2
    and now - (envelope.hullClock or 0) <= cfg.hullCacheTime then
    return envelope.hull, envelope
  end

  local veh = getObjectByID(vehId)
  if not veh then return nil, envelope end
  local ref = veh:getPosition()
  local points, allPoints = {}, {}
  for _, nodeId in ipairs(envelope.nodeIds) do
    local nodePos = veh:getNodePosition(nodeId)
    if nodePos then
      local world = ref + nodePos
      local flat = vec3(world.x, world.y, pathZ)
      allPoints[#allPoints + 1] = flat
      if world.z >= pathZ - cfg.collisionHeightBelow
        and world.z <= pathZ + cfg.collisionHeightAbove then
        points[#points + 1] = flat
      end
    end
  end
  if #points < 3 then points = allPoints end
  local hull = convexHull2D(points)
  if hull then
    envelope.hull = hull
    envelope.hullZ = pathZ
    envelope.hullClock = now
    envelope.hullVertexCount = #hull
  end
  return hull, envelope
end

local function closestPointOnSegment2D(p, a, b)
  local ab = b - a
  ab.z = 0
  local lenSq = ab:squaredLength()
  if lenSq < 1e-9 then return vec3(a) end
  local t = clamp(((p - a):z0()):dot(ab) / lenSq, 0, 1)
  local result = a + ab * t
  result.z = p.z
  return result
end

local function hullSignedClearance2D(p, hull)
  if not hull or #hull < 3 then return math.huge end
  local inside = true
  local closest, minDistance = nil, math.huge
  for i = 1, #hull do
    local a = hull[i]
    local b = hull[i % #hull + 1]
    if cross2D(a, b, p) < -1e-6 then inside = false end
    local candidate = closestPointOnSegment2D(p, a, b)
    local distance = candidate:distance(p)
    if distance < minDistance then
      minDistance, closest = distance, candidate
    end
  end
  return inside and -minDistance or minDistance, closest, inside
end

local function hullCenter2D(hull, z)
  local center = vec3(0, 0, z or 0)
  for _, point in ipairs(hull or {}) do
    center.x = center.x + point.x
    center.y = center.y + point.y
  end
  if hull and #hull > 0 then
    center.x = center.x / #hull
    center.y = center.y / #hull
  end
  return center
end

local function pushOutsideHull2D(p, hull, margin)
  margin = margin or 0
  local clearance, closest, inside = hullSignedClearance2D(p, hull)
  if not closest or clearance >= margin then return vec3(p) end
  local outward
  if inside then
    outward = (closest - p):z0()
  else
    outward = (p - closest):z0()
  end
  if outward:length() < 1e-4 then
    outward = (closest - hullCenter2D(hull, p.z)):z0()
  end
  if outward:length() < 1e-4 then outward = vec3(1, 0, 0) else outward:normalize() end
  local result = closest + outward * (margin + 0.05)
  result.z = p.z
  return result
end

local function vehicleClearance2D(p, vehId, margin)
  local hull, envelope = getCollisionHull(vehId, p.z)
  if hull then
    local clearance = hullSignedClearance2D(p, hull)
    return clearance - (margin or 0), "collisionHull", hull, envelope
  end
  local center, axis0, axis1 = getVehicleOBB(vehId)
  if center then
    return obbClearance2D(p, center, axis0, axis1, margin), "obbFallback", nil, envelope
  end
  return math.huge, "none", nil, envelope
end

local function pushOutsideVehicle2D(p, vehId, margin)
  local hull = getCollisionHull(vehId, p.z)
  if hull then return pushOutsideHull2D(p, hull, margin), "collisionHull" end
  local center, axis0, axis1 = getVehicleOBB(vehId)
  if center then
    return pushOutsideOBB2D(p, center, axis0, axis1, margin), "obbFallback"
  end
  return vec3(p), "none"
end

local function segmentsIntersect2D(a, b, c, d)
  local abC, abD = cross2D(a, b, c), cross2D(a, b, d)
  local cdA, cdB = cross2D(c, d, a), cross2D(c, d, b)
  if abC * abD > 1e-8 or cdA * cdB > 1e-8 then return false end
  return math.max(math.min(a.x, b.x), math.min(c.x, d.x))
      <= math.min(math.max(a.x, b.x), math.max(c.x, d.x)) + 1e-6
    and math.max(math.min(a.y, b.y), math.min(c.y, d.y))
      <= math.min(math.max(a.y, b.y), math.max(c.y, d.y)) + 1e-6
end

local function segmentDistance2D(a, b, c, d)
  if segmentsIntersect2D(a, b, c, d) then return 0 end
  return math.min(
    a:distance(closestPointOnSegment2D(a, c, d)),
    b:distance(closestPointOnSegment2D(b, c, d)),
    c:distance(closestPointOnSegment2D(c, a, b)),
    d:distance(closestPointOnSegment2D(d, a, b))
  )
end

local function segmentHitsHull2D(a, b, hull, margin)
  margin = margin or 0
  if hullSignedClearance2D(a, hull) < margin - 0.01
    or hullSignedClearance2D(b, hull) < margin - 0.01 then
    return true
  end
  for i = 1, #hull do
    local c = hull[i]
    local d = hull[i % #hull + 1]
    if segmentDistance2D(a, b, c, d) < margin - 0.01 then return true end
  end
  return false
end

local function expandHullVertices(hull, margin, z)
  local expanded = {}
  local amount = (margin or 0) + 0.10
  for i = 1, #hull do
    local prev = hull[(i - 2) % #hull + 1]
    local current = hull[i]
    local nextPoint = hull[i % #hull + 1]
    local prevEdge = (current - prev):z0()
    local nextEdge = (nextPoint - current):z0()
    if prevEdge:length() > 1e-5 then prevEdge:normalize() end
    if nextEdge:length() > 1e-5 then nextEdge:normalize() end
    local prevNormal = vec3(prevEdge.y, -prevEdge.x, 0)
    local nextNormal = vec3(nextEdge.y, -nextEdge.x, 0)
    local bisector = prevNormal + nextNormal
    if bisector:length() < 1e-4 then bisector = prevNormal else bisector:normalize() end
    local denominator = math.max(0.18, math.min(
      math.abs(bisector:dot(prevNormal)),
      math.abs(bisector:dot(nextNormal))
    ))
    local point = current + bisector * (amount / denominator)
    point.z = z
    expanded[#expanded + 1] = point
  end
  return expanded
end

local function buildCollisionHullRoute(pos, goal, hull, requestedMargin)
  local margin = requestedMargin or cfg.routeMargin
  local start = vec3(pos)
  local prefix = {}
  if hullSignedClearance2D(start, hull) < margin + 0.04 then
    local recoveryPad = requestedMargin and 0.06 or 0.24
    local safeStart = pushOutsideHull2D(start, hull, margin + recoveryPad)
    if safeStart:distance(start) > 0.04 then
      prefix[#prefix + 1] = vec3(safeStart)
      start = safeStart
    end
  end
  goal = pushOutsideHull2D(goal, hull, margin)
  if requestedMargin then
    -- Doorway motion is short and follows the body contour. Dense projected
    -- samples are more reliable here than a single visibility chord, which can
    -- cut across rounded running boards even when both endpoints are clear.
    local sampleCount = math.max(2, math.ceil(start:distance(goal) / 0.07))
    local route = prefix
    for i = 1, sampleCount do
      local t = i / sampleCount
      local sample = start * (1 - t) + goal * t
      sample = pushOutsideHull2D(sample, hull, margin)
      if #route == 0 or route[#route]:distance(sample) > 0.025 then
        route[#route + 1] = sample
      end
    end
    return #route > 0 and route or {vec3(goal)}
  end
  if not segmentHitsHull2D(start, goal, hull, margin) then
    prefix[#prefix + 1] = vec3(goal)
    return prefix
  end

  local expanded = expandHullVertices(hull, margin, pos.z)
  local nodes = {vec3(start)}
  for _, point in ipairs(expanded) do nodes[#nodes + 1] = point end
  nodes[#nodes + 1] = vec3(goal)
  local goalIndex = #nodes
  local distances, previous, visited = {}, {}, {}
  for i = 1, #nodes do distances[i] = math.huge end
  distances[1] = 0

  for _ = 1, #nodes do
    local current, best = nil, math.huge
    for i = 1, #nodes do
      if not visited[i] and distances[i] < best then current, best = i, distances[i] end
    end
    if not current then break end
    if current == goalIndex then break end
    visited[current] = true
    for nextIndex = 1, #nodes do
      if nextIndex ~= current and not visited[nextIndex]
        and not segmentHitsHull2D(nodes[current], nodes[nextIndex], hull, margin) then
        local candidate = distances[current] + nodes[current]:distance(nodes[nextIndex])
        if candidate < distances[nextIndex] then
          distances[nextIndex] = candidate
          previous[nextIndex] = current
        end
      end
    end
  end

  if distances[goalIndex] == math.huge then
    prefix[#prefix + 1] = vec3(goal)
    return prefix
  end
  local reverse, cursor = {}, goalIndex
  while cursor and cursor ~= 1 do
    reverse[#reverse + 1] = vec3(nodes[cursor])
    cursor = previous[cursor]
  end
  local route = prefix
  for i = #reverse, 1, -1 do route[#route + 1] = reverse[i] end
  return #route > 0 and route or {vec3(goal)}
end

local function requestCollisionEnvelope(veh, force)
  if not veh or veh:getJBeamFilename() == "unicycle" then return nil end
  local vehId = veh:getId()
  local existing = collisionEnvelopes[vehId]
  if existing and not force and (existing.pending or existing.nodeIds) then return existing end

  collisionEnvelopeRequestId = collisionEnvelopeRequestId + 1
  local requestId = collisionEnvelopeRequestId
  collisionEnvelopes[vehId] = {
    vehicleId = vehId,
    requestId = requestId,
    pending = true,
    requestedAt = os.clock(),
    model = veh:getJBeamFilename(),
    -- Keep the last topology usable until the refreshed live triangle set
    -- arrives from the vehicle VM.
    nodeIds = existing and existing.nodeIds or nil,
    nodeCount = existing and existing.nodeCount or nil,
    triangleCount = existing and existing.triangleCount or nil,
    bodyTriangleCount = existing and existing.bodyTriangleCount or nil,
    doorTriangleCount = existing and existing.doorTriangleCount or nil,
    hull = existing and existing.hull or nil,
    hullZ = existing and existing.hullZ or nil,
    hullClock = existing and existing.hullClock or nil,
    hullVertexCount = existing and existing.hullVertexCount or nil,
  }
  veh:queueLuaCommand(string.format(
    "extensions.load('overhaulCollisionEnvelope'); if overhaulCollisionEnvelope then overhaulCollisionEnvelope.requestCollisionEnvelope(%d) end",
    requestId
  ))
  return collisionEnvelopes[vehId]
end

local function receiveCollisionEnvelope(data)
  if type(data) ~= "table" then return false end
  local vehId = tonumber(data.vehicleId)
  local requestId = tonumber(data.requestId)
  if not vehId or type(data.nodeIds) ~= "table" then return false end
  local existing = collisionEnvelopes[vehId]
  if existing and requestId and requestId < (existing.requestId or 0) then return false end

  collisionEnvelopes[vehId] = {
    vehicleId = vehId,
    requestId = requestId or 0,
    pending = false,
    receivedAt = os.clock(),
    model = existing and existing.model or nil,
    nodeIds = data.nodeIds,
    nodeCount = #data.nodeIds,
    triangleCount = tonumber(data.triangleCount) or 0,
    bodyTriangleCount = tonumber(data.bodyTriangleCount) or 0,
    doorTriangleCount = tonumber(data.doorTriangleCount) or 0,
  }
  if approach and approach.vehId == vehId then
    approach.collisionEnvelopeReceived = true
    approach.collisionEnvelopePending = false
    approach.collisionNodeCount = #data.nodeIds
    approach.collisionTriangleCount = tonumber(data.triangleCount) or 0
    approach.collisionBodyTriangleCount = tonumber(data.bodyTriangleCount) or 0
    approach.collisionDoorTriangleCount = tonumber(data.doorTriangleCount) or 0
    if approach.phase == "approach" then
      approach.route = nil
      approach.routeIndex = 1
      approach.waypoint = nil
    end
  end
  return true
end

-- how strongly fromPos is behind the door along vehicle forward (0..1)
local function getApproachAftFactor(fromPos, doorCenter, fwd, halfLength)
  if not fromPos or not doorCenter or not fwd then return 0 end
  local along = (fromPos - doorCenter):z0():dot(fwd)
  return clamp(-along / math.max(halfLength * 0.75, 0.5), 0, 1)
end

-- Stand behind the latch arc as well as outside the body. Controller-backed doors
-- receive a larger envelope so their force-open animation cannot collide with the
-- walking capsule, including when the approach began behind the vehicle.
local function getStandPos(veh, fromPos, lockedDoorName, lockedAftFactor, lockedDoorInfo)
  fromPos = fromPos or veh:getPosition()
  local doorInfo = lockedDoorInfo or findDriverDoorInfo(veh)
  local doorName = lockedDoorName
  local doorCenter
  if lockedDoorInfo and lockedDoorInfo.referenceLocal then
    doorCenter = vehicleLocalPointToWorld(veh, lockedDoorInfo.referenceLocal)
  elseif lockedDoorInfo and lockedDoorInfo.center then
    doorCenter = vec3(lockedDoorInfo.center)
  elseif doorName then
    doorCenter = getDoorTriggerCenter(veh, doorName)
  else
    doorName, doorCenter = getClosestDoorName(veh, fromPos)
  end

  local fwd = veh:getDirectionVector():z0()
  if fwd:length() > 1e-4 then fwd:normalize() else fwd = vec3(0, 1, 0) end
  local center, axis0, axis1 = getVehicleOBB(veh:getId())
  local halfLength, halfWidth = 2.2, 0.95
  if axis0 and axis1 then
    local len0 = axis0:z0():length()
    local len1 = axis1:z0():length()
    halfLength = math.max(len0, len1)
    halfWidth = math.min(len0, len1)
  end
  local aftFactor = lockedAftFactor
  if aftFactor == nil then
    aftFactor = getApproachAftFactor(fromPos, doorCenter or veh:getPosition(), fwd, halfLength)
  end
  local hasSwingingDoor = doorInfo and doorInfo.controllerName ~= nil
  local standMargin = hasSwingingDoor and cfg.doorWaitClearance or cfg.bodyClearance
  -- Clearance comes from standing just behind the panel rather than backing a
  -- full metre away from the whole vehicle. This keeps the player close while
  -- leaving the outward/forward swing path empty.
  local standOut = halfWidth * cfg.standOutFraction * (1 - 0.2 * aftFactor)
  local backReduction = hasSwingingDoor and 0.55 or 0.9
  local standBack = halfLength * cfg.standBackFraction * (1 - backReduction * aftFactor)
  local safeStandLongSign = doorInfo and doorInfo.safeStandLongSign or -1

  local stand, front
  if doorCenter then
    local outward = (doorCenter - veh:getPosition()):z0()
    if outward:length() < 1e-3 then
      local left = veh:getDirectionVectorUp():cross(fwd)
      if left:length() > 1e-4 then
        left:normalize()
        outward = (doorName == "door_R") and -left or left
      else
        outward = vec3(1, 0, 0)
      end
    else
      outward:normalize()
    end
    stand = doorCenter + outward * standOut + fwd * (standBack * safeStandLongSign)
    -- from behind, nudge slightly forward along the door so board starts closer
    if aftFactor > 0.15 then
      local forwardNudge = hasSwingingDoor and 0.025 or 0.08
      stand = stand + fwd * (halfLength * forwardNudge * aftFactor)
    end
    front = -outward
  else
    local doorside, dFront = gameplay_walk.getDoorsidePosRot(veh)
    if not doorside then
      return nil, nil, nil, doorName, aftFactor
    end
    stand = doorside - fwd * standBack
    front = dFront
    doorCenter = doorside
  end

  do
    stand = pushOutsideVehicle2D(stand, veh:getId(), standMargin)
    local hull = getCollisionHull(veh:getId(), stand.z)
    local envelopeCenter = hull and hullCenter2D(hull, stand.z) or center or veh:getPosition()
    local guard = 0
    local clearance = vehicleClearance2D(stand, veh:getId(), 0)
    while clearance < standMargin and guard < 12 do
      local away = (stand - envelopeCenter):z0()
      if away:length() < 1e-4 then break end
      away:normalize()
      -- prefer pushing sideways over further aft when approaching from behind
      if aftFactor > 0.25 then
        local side = away - fwd * away:dot(fwd)
        if side:length() > 0.2 then
          away = side:normalized()
        end
      end
      stand = stand + away * 0.25
      guard = guard + 1
      clearance = vehicleClearance2D(stand, veh:getId(), 0)
    end
  end
  if doorCenter and doorInfo then
    local left = getVehicleLeft2D(veh)
    local desiredSign = doorInfo.side == "R" and -1 or 1
    local lateral = getLateralOffset(veh, stand)
    if left and lateral and lateral * desiredSign <= 0.08 then
      local sideDir = left * desiredSign
      stand = doorCenter + sideDir * (halfWidth + standMargin + 0.05)
        + fwd * (standBack * safeStandLongSign)
      stand = pushOutsideVehicle2D(stand, veh:getId(), standMargin)
    end
  end
  -- Door/driver nodes on trucks and heavy equipment can be several metres above the
  -- ground. Navigation is horizontal; keep the walking target on the player's plane.
  stand.z = fromPos.z
  return stand, front, doorCenter, doorName, aftFactor, standMargin
end

local function getDoorEntryPos(veh, doorCenter, pathZ)
  if not veh or not doorCenter then return nil end
  local outward = (doorCenter - veh:getPosition()):z0()
  if outward:length() < 1e-4 then
    local fwd = veh:getDirectionVector():z0()
    if fwd:length() > 1e-4 then fwd:normalize() else fwd = vec3(0, 1, 0) end
    outward = veh:getDirectionVectorUp():cross(fwd)
  end
  if outward:length() > 1e-4 then outward:normalize() else outward = vec3(1, 0, 0) end

  local entry = vec3(doorCenter.x, doorCenter.y, pathZ or doorCenter.z)
  entry = entry + outward * 0.08
  -- The Nine's low, wide running board sits outside the apparent door opening.
  -- Keep the close-first pocket unchanged, then give the walking capsule enough
  -- room to follow the doorway without clipping the sideskirt triangles.
  local entryClearance = veh:getJBeamFilename() == "nine" and 0.42 or cfg.entryStepClearance
  entry = pushOutsideVehicle2D(entry, veh:getId(), entryClearance)
  entry.z = pathZ or entry.z
  return entry
end

-- First move inward while remaining beyond the latch on the hinge-safe side.
-- The second boarding leg can then travel along the body toward the doorway,
-- instead of cutting diagonally through the open panel's swept volume.
local function getDoorPocketPos(veh, doorCenter, safeStandLongSign, doorSpan, pathZ)
  if not veh or not doorCenter then return nil end
  local fwd = veh:getDirectionVector():z0()
  if fwd:length() > 1e-4 then fwd:normalize() else fwd = vec3(0, 1, 0) end
  local safeSign = safeStandLongSign == 1 and 1 or -1
  local longOffset = math.max((tonumber(doorSpan) or 0.60) * 0.82, cfg.entryPocketLength)
  local pocket = vec3(doorCenter.x, doorCenter.y, pathZ or doorCenter.z)
    + fwd * (longOffset * safeSign)
  local pocketClearance = veh:getJBeamFilename() == "nine" and 0.42 or cfg.entryCloseClearance
  pocket = pushOutsideVehicle2D(pocket, veh:getId(), pocketClearance)
  pocket.z = pathZ or pocket.z
  return pocket
end

-- 2D segment vs expanded OBB (ignore vertical axis)
local function segmentHitsOBB2D(a, b, center, axis0, axis1, margin)
  local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, margin)
  if not c2 then return false end

  local function toLocal(p)
    return localOBBCoords(p, c2, u0, u1)
  end

  local x1, y1 = toLocal(a)
  local x2, y2 = toLocal(b)
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = 0, 1

  local function clip(p, q)
    if math.abs(p) < 1e-9 then
      return q >= 0
    end
    local r = q / p
    if p < 0 then
      if r > t1 then return false end
      if r > t0 then t0 = r end
    else
      if r < t0 then return false end
      if r < t1 then t1 = r end
    end
    return true
  end

  if not clip(-dx, x1 + e0) then return false end
  if not clip(dx, e0 - x1) then return false end
  if not clip(-dy, y1 + e1) then return false end
  if not clip(dy, e1 - y1) then return false end
  return t0 <= t1
end

local function buildRoute(pos, goal, vehId, margin)
  local hull, envelope = getCollisionHull(vehId, pos.z)
  if hull then
    return buildCollisionHullRoute(pos, goal, hull, margin), "collisionHull", hull, envelope
  end
  local center, axis0, axis1 = getVehicleOBB(vehId)
  if not center then return {vec3(goal)}, "none", nil, envelope end

  goal = pushOutsideOBB2D(goal, center, axis0, axis1, cfg.obbMargin)
  if not segmentHitsOBB2D(pos, goal, center, axis0, axis1, cfg.obbMargin) then
    return {vec3(goal)}, "obbFallback", nil, envelope
  end

  local c2, u0, u1, e0, e1 = getOBBBasis2D(center, axis0, axis1, cfg.obbMargin + 0.25)
  if not c2 then return {vec3(goal)}, "obbFallback", nil, envelope end
  local x0, y0 = u0 * e0, u1 * e1
  local corners = {
    c2 + x0 + y0,
    c2 + x0 - y0,
    c2 - x0 + y0,
    c2 - x0 - y0
  }
  for _, corner in ipairs(corners) do
    corner.z = pos.z
  end

  local function clear(a, b)
    return not segmentHitsOBB2D(a, b, center, axis0, axis1, cfg.obbMargin)
  end

  local bestRoute, bestCost = nil, math.huge
  for i, first in ipairs(corners) do
    if clear(pos, first) then
      if clear(first, goal) then
        local cost = pos:distance(first) + first:distance(goal)
        if cost < bestCost then
          bestCost = cost
          bestRoute = {vec3(first), vec3(goal)}
        end
      end
      for j, second in ipairs(corners) do
        if i ~= j and clear(first, second) and clear(second, goal) then
          local cost = pos:distance(first) + first:distance(second) + second:distance(goal)
          if cost < bestCost then
            bestCost = cost
            bestRoute = {vec3(first), vec3(second), vec3(goal)}
          end
        end
      end
    end
  end

  return bestRoute or {vec3(goal)}, "obbFallback", nil, envelope
end

local function noteCollisionEnvelope(state, source, hull, envelope)
  if not state then return end
  if source then state.pathEnvelopeSource = source end
  if hull then state.collisionHullVertexCount = #hull end
  envelope = envelope or collisionEnvelopes[state.vehId]
  if envelope then
    state.collisionEnvelopePending = envelope.pending == true
    state.collisionNodeCount = envelope.nodeCount
      or (envelope.nodeIds and #envelope.nodeIds)
      or state.collisionNodeCount
    state.collisionTriangleCount = envelope.triangleCount or state.collisionTriangleCount
    state.collisionBodyTriangleCount = envelope.bodyTriangleCount or state.collisionBodyTriangleCount
    state.collisionDoorTriangleCount = envelope.doorTriangleCount or state.collisionDoorTriangleCount
    state.collisionHullVertexCount = envelope.hullVertexCount or state.collisionHullVertexCount
  end
end

local function getSteerTarget(pos, goal, vehId, margin, waypointDistance)
  if approach.route then
    while approach.routeIndex <= #approach.route
      and pos:distance(approach.route[approach.routeIndex])
        < (waypointDistance or cfg.waypointDistance) do
      approach.routeIndex = approach.routeIndex + 1
    end
    if approach.routeIndex <= #approach.route then
      local target = approach.route[approach.routeIndex]
      approach.waypoint = approach.routeIndex < #approach.route and target or nil
      return target
    end
    approach.route = nil
  end

  local route, source, hull, envelope = buildRoute(pos, goal, vehId, margin)
  approach.route = route
  approach.routeIndex = 1
  approach.waypointCount = approach.waypointCount + math.max(#approach.route - 1, 0)
  noteCollisionEnvelope(approach, source, hull, envelope)
  local target = approach.route[1]
  approach.waypoint = #approach.route > 1 and target or nil
  return target
end

local function storeApproachStats(reason)
  if not approach then return end
  local stats = {reason = reason}
  copyStateFields(stats, approach, [[model minClearance maxClearance doorName doorSide
    driverNodeId driverLateral driverSideSource driverHalfWidth driverSideThreshold
    doorTriggerName doorControllerName doorReferenceSource doorTriggerLateral
    doorReferenceLateral hingeLongSign safeStandLongSign doorSpan doorStateBefore
    doorStateAfter doorOpenStateAfter doorCloseStateAfter speedCoef t phase doorGap
    doorOpenForceDuration doorCloseForceDuration doorCommandT doorCommandStandDistance
    doorCommandDoorDistance doorCommandClearance doorCommandPlayerLateral
    doorCommandExpectedLateral doorCommandSelectedDoorLateral
    doorCommandPlayerLongitudinal doorCommandDoorLongitudinal doorCommandSwingClearance
    doorFullEvidence standClearance standMargin skipReason skipAtT entrySwitchT
    entryCloseStartDistance entryCloseFinalDistance entryCloseStartClearance
    entryCloseTargetClearance entryStepStartDistance entryStepFinalDistance
    entryStepPlannedLongitudinal entryStepPlannedLateral entryStepTargetClearance
    reachAssistReason targetCameraName boardingVerticalMode seatHeightDelta
    boardCameraEndpointError startDistance minDistance maxDistance finalDistance
    minLookMoveDot pathEnvelopeSource]])
  copyStateFields(stats, approach, [[doorTriggerCenterValid doorControllerFound
    doorOpened doorClosed doorPhysicalMeasured doorCommandSideAligned doorFullyOpened
    doorOpenTimedOut skipped entryCloseCompleted entryStepCompleted doorwayBoard
    reachAssist boardCameraEndpointReached collisionEnvelopePending]], "bool")
  copyStateFields(stats, approach, [[insideHits arriveT boardT maxDoorGap
    wrongSideCorrections swingClearanceCorrections doorStableProbes entryCloseT
    entryCloseTravel entrySettleT entryStepT entryStepTravel collisionRecoveryCount
    reachAssistDistance pathLength maxSpeed maxLookRateDeg totalLookTurnDeg
    maxCameraTargetErrorDeg waypointCount collisionNodeCount collisionTriangleCount
    collisionBodyTriangleCount collisionDoorTriangleCount collisionHullVertexCount]], "zero")
  stats.doorOpenWait = approach.doorOpenWait or approach.doorOpenElapsed or 0
  stats.doorCloseAttempts =
    (approach.closeRetryCount or 0) + (approach.closeCommanded and 1 or 0)
  stats.driverTransition = approach.useDriverTransition == true
  stats.collisionEnvelopeFallback = approach.pathEnvelopeSource ~= "collisionHull"
  stats.pathEfficiency = stats.pathLength > 0
    and (approach.startDistance or 0) / stats.pathLength or 0
  stats.avgSpeed = (approach.speedSum or 0) / math.max(approach.speedSamples or 0, 1)
  stats.avgLookMoveDot =
    (approach.lookMoveDotSum or 0) / math.max(approach.lookSamples or 0, 1)
  stats.avgLookCarDot =
    (approach.lookCarDotSum or 0) / math.max(approach.lookSamples or 0, 1)
  stats.boardStartCameraPos = vecToTable(approach.boardStartCameraPos)
  stats.boardTargetCameraPos = vecToTable(approach.boardTargetCameraPos)
  lastApproachStats = stats
end
local function cancelApproach(reason)
  if not approach then return end
  storeApproachStats(reason or "cancel")
  local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or getPlayerVehicle(0)
  clearExternalMove(unicycle)
  setWalkingCameraTransition(unicycle, nil)
  approach = nil
end

local function finishEnter(veh, options)
  options = options or {}
  if not isEnterableVehicle(veh) then
    cancelApproach("vehicleUnavailable")
    return false
  end
  local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
  local finished = approach
  if finished then
    finished.skipped = options.skipped == true or finished.skipped == true
    finished.skipReason = options.skipReason or finished.skipReason
    finished.skipAtT = finished.skipped and (finished.skipAtT or finished.t or 0) or nil
    finished.entrySwitchT = finished.t or 0
    if finished.doorControllerName and not finished.doorCommanded then
      finished.doorOpenElapsed = finished.doorOpenElapsed or 0
      finished.doorProbeCount = finished.doorProbeCount or 0
      finished.doorCommanded = ensureDoorState(
        veh, finished.doorControllerName, true, "entry"
      )
    end
  end
  storeApproachStats("enter")
  clearExternalMove(unicycle)
  setWalkingCameraTransition(unicycle, nil)
  approach = nil
  if veh then
    if finished and finished.useDriverTransition then
      driverSettle = prepareDriverSettle(
        veh,
        finished.boardingVerticalMode
      )
    end
    -- Match stock walk.lua so career inventory records the seated vehicle.
    extensions.hook("onBeforeWalkingModeToggled", false, veh:getId())
    gameplay_walk.getInVehicle(veh)
    postEnter = {
      vehId = veh:getId(),
      t = 0,
      controllerName = finished and finished.doorControllerName,
      doorControllerName = finished and finished.doorControllerName,
      doorControllerFound = finished and finished.doorControllerFound,
      doorStateBefore = finished and finished.doorStateBefore,
      doorStateAfter = finished and finished.doorStateAfter,
      doorOpenStateAfter = finished and finished.doorOpenStateAfter,
      doorOpened = finished and finished.doorOpened,
      doorGap = finished and finished.doorGap,
      maxDoorGap = finished and finished.maxDoorGap or 0,
      doorPhysicalMeasured = finished and finished.doorPhysicalMeasured,
      doorOpenForceDuration = finished and finished.doorOpenForceDuration,
      doorCloseForceDuration = finished and finished.doorCloseForceDuration,
      doorOpenElapsed = finished and finished.doorOpenElapsed or 0,
      doorOpenWait = finished and finished.doorOpenWait,
      doorFullyOpened = finished and finished.doorFullyOpened,
      doorOpenReady = finished and finished.doorOpenReady,
      doorFullEvidence = finished and finished.doorFullEvidence,
      doorOpenTimedOut = finished and finished.doorOpenTimedOut,
      doorStableProbes = finished and finished.doorStableProbes or 0,
      previousDoorGap = finished and finished.previousDoorGap,
      doorProbeCount = finished and finished.doorProbeCount or 0,
      nextDoorProbeT = finished and finished.nextDoorProbeT or 0,
      skipped = finished and finished.skipped,
      closeCommanded = false
    }
  end
  return true
end

local function skipApproach(skipReason)
  if not approach then return false end
  local veh = getObjectByID(approach.vehId)
  if not veh then
    cancelApproach("vehicleMissing")
    return false
  end
  finishEnter(veh, {skipped = true, skipReason = skipReason or "repeatInput"})
  guihooks.trigger("Message", {category = "walkingmode", clear = true})
  return true
end

local function captureSpeedCoef(unicycle)
  -- Keep automated entry independent of the player's current sprint input, but
  -- use a predictable brisk approach. The final metre still eases back to the
  -- normal walking speed in updateApproach so doorway placement stays precise.
  return cfg.approachSpeedCoef
end

local function getCameraLookDir()
  local q = core_camera.getQuat()
  if not q then return nil end
  local dir = q * vec3(0, 1, 0)
  if dir:length() < 1e-4 then return nil end
  return dir:normalized()
end

local function getLookOrigin(fallbackPos)
  local camPos = core_camera.getPosition and core_camera.getPosition() or nil
  if camPos then return camPos end
  return (fallbackPos or vec3()) + vec3(0, 0, 1.6)
end

boardingCamera.getDriverWorldPos = function(veh, driverNodeId)
  if not veh then return nil end
  local nodeId = driverNodeId
  if nodeId == nil then nodeId = core_camera.getDriverData(veh) end
  local nodePos = nodeId ~= nil and veh:getNodePosition(nodeId) or nil
  if not nodePos then return nil end

  local target = veh:getPosition() + nodePos
  local camData = core_camera.getCameraDataById(veh:getId())
  local driverCam = camData and camData.driver
  local seat = driverCam and driverCam.seatPosition
  if seat then
    local left, fwd, bodyUp = getVehicleBasis(veh)
    if left then
      target = target + left * (seat.x or 0)
        + fwd * (seat.y or 0) + bodyUp * (seat.z or 0)
    end
  end
  return target
end

boardingCamera.getWalkingBasePos = function(unicycle)
  if not unicycle then return nil end
  local nodeId = core_camera.getDriverData(unicycle)
  local nodePos = nodeId ~= nil and unicycle:getNodePosition(nodeId) or nil
  return nodePos and (unicycle:getPosition() + nodePos) or nil
end

boardingCamera.getForwardDir = function(veh)
  if not veh then return nil end
  local fwd = veh:getDirectionVector()
  if fwd:length() < 1e-4 then return nil end
  fwd:normalize()
  return fwd
end

setWalkingCameraTransition = function(unicycle, data)
  if not unicycle then return false end
  local camData = core_camera.getCameraDataById(unicycle:getId())
  local cam = camData and camData.unicycle
  if cam and cam.setScriptedTransition then
    cam:setScriptedTransition(data)
    return true
  end
  return false
end

prepareDriverSettle = function(veh, mode)
  if not veh then return nil end
  return {
    vehId = veh:getId(),
    t = 0,
    pendingT = 0,
    duration = cfg.driverSettleDuration,
    mode = mode or "level"
  }
end

local function restoreDriverCamera(state)
  if not state or not state.cam then return end
  state.cam.seatPosition = vec3(state.basePos)
  state.cam.seatRotation = state.baseRotation
end

local function updateDriverSettle(dt)
  if not driverSettle then return end
  local state = driverSettle
  local veh = getObjectByID(state.vehId)
  if not veh then
    restoreDriverCamera(state)
    driverSettle = nil
    return
  end
  if not state.cam then
    state.pendingT = (state.pendingT or 0) + dt
    local camData = core_camera.getCameraDataById(veh:getId())
    local cam = camData and camData.driver
    if not cam or not cam.seatPosition then
      if state.pendingT >= 0.45 then driverSettle = nil end
      return
    end
    state.cam = cam
    state.basePos = vec3(cam.seatPosition)
    state.baseRotation = cam.seatRotation or 0
  end
  state.t = state.t + dt
  local p = clamp(state.t / state.duration, 0, 1)
  local cushion = math.sin(p * math.pi)
  cushion = cushion * cushion
  local cushionZ = state.mode == "low" and -0.008 * cushion
    or state.mode == "high" and 0.010 * cushion or 0
  state.cam.seatPosition = state.basePos + vec3(0, 0, cushionZ)
  state.cam.seatRotation = state.baseRotation
  if p >= 1 then
    restoreDriverCamera(state)
    driverSettle = nil
  end
end

local function dirToYawPitch(dir)
  local flatLen = math.sqrt(dir.x * dir.x + dir.y * dir.y)
  local yaw = math.atan2(dir.y, dir.x)
  local pitch = math.atan2(dir.z, math.max(flatLen, 1e-6))
  return yaw, clamp(pitch, -math.rad(89), math.rad(89))
end

local function yawPitchToDir(yaw, pitch)
  local cp = math.cos(pitch)
  return vec3(math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch))
end

local function smoothLookDir(current, target, dt, rate, pitchRate, maxRate, maxPitchRate)
  if not target then return current end
  if not current then return target end
  rate = rate or cfg.lookRate
  pitchRate = pitchRate or cfg.lookPitchRate
  maxRate = maxRate or cfg.lookMaxRate
  maxPitchRate = maxPitchRate or cfg.lookMaxPitchRate
  local currentYaw, currentPitch = dirToYawPitch(current)
  local targetYaw, targetPitch = dirToYawPitch(target)
  local yawDelta = (targetYaw - currentYaw + math.pi) % (2 * math.pi) - math.pi
  local pitchDelta = targetPitch - currentPitch
  local yawStep = yawDelta * (1 - math.exp(-dt * rate))
  local pitchStep = pitchDelta * (1 - math.exp(-dt * pitchRate))
  yawStep = clamp(yawStep, -maxRate * dt, maxRate * dt)
  pitchStep = clamp(pitchStep, -maxPitchRate * dt, maxPitchRate * dt)
  return yawPitchToDir(currentYaw + yawStep, currentPitch + pitchStep)
end

boardingCamera.lookInDirection = function(targetDir, dt, boarding)
  if not approach or not targetDir or targetDir:length() < 1e-4 then return end
  targetDir = targetDir:normalized()
  approach.lookDir = smoothLookDir(
    approach.lookDir, targetDir, dt,
    boarding and cfg.boardLookRate or nil,
    boarding and 3.80 or nil,
    boarding and cfg.boardLookMaxRate or nil,
    boarding and math.rad(70) or nil
  )
  gameplay_walk.setRot(approach.lookDir, up)
end

local function lookAtVehicle(pos, lookPos, dt)
  if not lookPos then return end
  local toLook = lookPos - getLookOrigin(pos)
  if toLook:length() < 1e-3 then return end
  toLook:normalize()
  approach.lookDir = smoothLookDir(approach.lookDir, toLook, dt)
  gameplay_walk.setRot(approach.lookDir, up)
end

local function startApproach(veh)
  if not isRealisticEntryEnabled() then return false end
  if not isEnterableVehicle(veh) or not gameplay_walk.isWalking() then return false end
  if not gameplay_walk.isAtParkingSpeed or not gameplay_walk.isAtParkingSpeed() then return false end

  lastApproachStats = nil
  local unicycle = gameplay_walk.getCurrentUnicycle()
  if not unicycle then return false end

  -- Refresh the active collidable triangle set at the moment of entry. The
  -- response is asynchronous; cached topology remains usable, and a first-time
  -- request briefly falls back to the OBB before rebuilding the route.
  local collisionEnvelope = requestCollisionEnvelope(veh, true)
  local fromPos = unicycle:getPosition()
  local doorInfo = findDriverDoorInfo(veh)
  local lockedDoorName = doorInfo and (doorInfo.triggerName or doorInfo.canonicalName) or nil
  local standPos, front, doorCenter, doorName, aftFactor, standMargin = getStandPos(
    veh, fromPos, lockedDoorName, nil, doorInfo
  )
  if not standPos then
    extensions.hook("onBeforeWalkingModeToggled", false, veh:getId())
    gameplay_walk.getInVehicle(veh)
    return true
  end
  aftFactor = aftFactor or 0

  local targetCameraName = core_camera.getActiveCamNameByVehId(veh:getId())
  local useDriverTransition = targetCameraName == "driver"
  if useDriverTransition then
    core_camera.setVehicleCameraByNameWithId(unicycle:getId(), "unicycle", false, {})
  end

  local vehRef = getVehicleRefPos(veh)
  local vehLook = getVehicleLookPos(veh)
  local dist = fromPos:distance(standPos)
  local lookStart = getCameraLookDir()
  local toVehLook = vehLook and (vehLook - getLookOrigin(fromPos)) or nil
  if toVehLook and toVehLook:length() > 1e-4 then
    toVehLook:normalize()
  else
    toVehLook = nil
  end
  local toStand = (standPos - fromPos):z0()
  if toStand:length() > 1e-4 then toStand:normalize() else toStand = lookStart or vec3(0, 1, 0) end

  local startPlayerLong = getLongitudinalOffset(veh, fromPos)
  local startDoorLong = getLongitudinalOffset(veh, doorCenter)
  local startSwingClearance = startPlayerLong and startDoorLong
    and (startPlayerLong - startDoorLong) * (doorInfo and doorInfo.safeStandLongSign or -1)
    or nil
  local requiredSwingClearance = doorInfo and doorInfo.controllerName
    and math.max(0.18, (doorInfo.doorSpan or 0.60) * 0.25) or nil
  local alreadyThere = dist <= cfg.arrive
    and (not requiredSwingClearance or not startSwingClearance
      or startSwingClearance >= requiredSwingClearance)
  local standClearance, standEnvelopeSource, standHull, standEnvelope = vehicleClearance2D(
    standPos, veh:getId(), 0
  )
  local startWaypoint = nil
  local startClearance = vehicleClearance2D(fromPos, veh:getId(), 0)
  if not alreadyThere and startClearance < cfg.bodyClearance then
    startWaypoint = pushOutsideVehicle2D(
      fromPos, veh:getId(), math.max(cfg.routeMargin, cfg.bodyClearance) + 0.2
    )
    local center = standHull and hullCenter2D(standHull, fromPos.z) or getVehicleOBB(veh:getId())
    local away = center and (startWaypoint - center):z0() or vec3()
    if away:length() > 1e-4 then
      away:normalize()
      startWaypoint = startWaypoint + away * 0.4
    end
  end

  local route, pathEnvelopeSource, pathHull, pathEnvelope = {}, standEnvelopeSource, standHull, standEnvelope
  if not alreadyThere then
    if startWaypoint then
      route[#route + 1] = startWaypoint
    end
    local builtRoute, builtSource, builtHull, builtEnvelope = buildRoute(
      startWaypoint or fromPos, standPos, veh:getId()
    )
    pathEnvelopeSource = builtSource or pathEnvelopeSource
    pathHull = builtHull or pathHull
    pathEnvelope = builtEnvelope or pathEnvelope
    for _, point in ipairs(builtRoute) do
      route[#route + 1] = point
    end
  else
    route[1] = standPos
  end
  local boardDoorLocal = doorCenter and worldPointToVehicleLocal(veh, doorCenter) or nil
  local doorReferenceLateral = getLateralOffset(veh, doorCenter)

  approach = {
    vehId = veh:getId(),
    model = veh:getJBeamFilename(),
    t = 0,
    arriveT = 0,
    boardT = 0,
    phase = alreadyThere and "waitDoor" or "approach",
    arrived = alreadyThere,
    standPos = standPos,
    doorCenter = doorCenter,
    vehRef = vehRef,
    aftFactor = aftFactor,
    boardDoorRef = doorCenter and vec3(doorCenter) or nil,
    boardDoorLocal = boardDoorLocal,
    boardTarget = alreadyThere and getBoardTarget(veh, doorCenter, aftFactor) or nil,
    doorName = doorName,
    doorSide = doorInfo and doorInfo.side,
    driverNodeId = doorInfo and doorInfo.driverNodeId,
    driverLateral = doorInfo and doorInfo.driverLateral,
    driverHalfWidth = doorInfo and doorInfo.driverHalfWidth,
    driverSideThreshold = doorInfo and doorInfo.driverSideThreshold,
    driverSideSource = doorInfo and doorInfo.sideSource,
    doorTriggerName = doorInfo and doorInfo.triggerName,
    doorControllerName = doorInfo and doorInfo.controllerName,
    doorReferenceSource = doorInfo and doorInfo.referenceSource,
    doorTriggerCenterValid = doorInfo and doorInfo.triggerCenterValid == true,
    doorTriggerLateral = doorInfo and doorInfo.triggerLateral,
    doorReferenceLateral = doorReferenceLateral,
    hingeLongSign = doorInfo and doorInfo.hingeLongSign,
    safeStandLongSign = doorInfo and doorInfo.safeStandLongSign,
    doorSpan = doorInfo and doorInfo.doorSpan,
    doorInfo = doorInfo,
    maxDoorGap = 0,
    doorOpenElapsed = 0,
    doorProbeCount = 0,
    nextDoorProbeT = 0,
    standMargin = standMargin,
    standClearance = standClearance,
    targetCameraName = targetCameraName,
    useDriverTransition = useDriverTransition,
    front = front,
    speedCoef = captureSpeedCoef(unicycle),
    route = route,
    routeIndex = 1,
    waypoint = #route > 1 and route[1] or nil,
    lookDir = lookStart or toVehLook or toStand,
    minClearance = math.huge,
    maxClearance = -math.huge,
    insideHits = 0,
    pathLength = 0,
    stallWindowT = 0,
    stallWindowPath = 0,
    collisionRecoveryCount = 0,
    prevPos = vec3(fromPos),
    startDistance = dist,
    minDistance = dist,
    maxDistance = dist,
    speedSum = 0,
    speedSamples = 0,
    maxSpeed = 0,
    lookMoveDotSum = 0,
    lookCarDotSum = 0,
    lookSamples = 0,
    minLookMoveDot = 1,
    maxLookRateDeg = 0,
    totalLookTurnDeg = 0,
    maxCameraTargetErrorDeg = 0,
    prevActualLook = lookStart and vec3(lookStart) or nil,
    waypointCount = math.max(#route - 1, 0),
    pathEnvelopeSource = pathEnvelopeSource,
    collisionEnvelopePending = collisionEnvelope and collisionEnvelope.pending == true,
    collisionNodeCount = (pathEnvelope and pathEnvelope.nodeCount)
      or (collisionEnvelope and collisionEnvelope.nodeCount),
    collisionTriangleCount = (pathEnvelope and pathEnvelope.triangleCount)
      or (collisionEnvelope and collisionEnvelope.triangleCount),
    collisionBodyTriangleCount = (pathEnvelope and pathEnvelope.bodyTriangleCount)
      or (collisionEnvelope and collisionEnvelope.bodyTriangleCount),
    collisionDoorTriangleCount = (pathEnvelope and pathEnvelope.doorTriangleCount)
      or (collisionEnvelope and collisionEnvelope.doorTriangleCount),
    collisionHullVertexCount = pathHull and #pathHull
      or (pathEnvelope and pathEnvelope.hullVertexCount)
  }

  guihooks.trigger("Message", {
    ttl = 8,
    msg = "Entering vehicle...",
    category = "walkingmode",
    icon = "seatArrowInLeft"
  })
  return true
end

local function getNearestEnterableVehicle()
  local unicycle = gameplay_walk.getCurrentUnicycle()
  if not unicycle then return nil end
  local pos = unicycle:getPosition()
  local best, bestDist = nil, math.huge
  for _, veh in ipairs(getAllVehicles()) do
    if isEnterableVehicle(veh) then
      local standPos = getStandPos(veh, pos)
      if standPos then
        local d = pos:distance(standPos)
        if d < bestDist then
          bestDist = d
          best = veh
        end
      end
    end
  end
  return best, bestDist
end

local function restoreExitDriverCamera(state)
  if not state or not state.driverCam then return end
  state.driverCam.relativeYaw = state.driverYaw or 0
  state.driverCam.relativePitch = state.driverPitch or 0
end

local function storeExitStats(reason)
  if not exitTransition then return end
  local state = exitTransition
  local stats = {reason = reason}
  copyStateFields(stats, state, [[vehId model phase doorSide doorTriggerName
    doorControllerName doorReferenceSource doorTriggerLateral doorReferenceLateral
    doorStateBefore doorStateAfter doorOpenStateAfter doorCloseStateAfter doorGap
    doorOpenForceDuration doorCloseForceDuration doorFullEvidence standClearance
    standMargin exitSwitchT doorFullyOpenT targetCameraName startCameraPos]])
  copyStateFields(stats, state, [[doorTriggerCenterValid doorControllerFound
    doorOpened doorClosed doorPhysicalMeasured doorFullyOpened doorOpenTimedOut]], "bool")
  copyStateFields(stats, state, "t maxDoorGap doorStableProbes", "zero")
  stats.doorOpenWait = state.doorOpenWait or state.doorOpenElapsed or 0
  stats.doorCloseAttempts =
    (state.closeRetryCount or 0) + (state.closeCommanded and 1 or 0)
  stats.switchAfterDoorReady = state.exitSwitchT and state.doorFullyOpenT
    and state.exitSwitchT - state.doorFullyOpenT or nil
  stats.driverTransition = state.useDriverTransition == true
  stats.finalCameraPos =
    vecToTable(core_camera.getPosition and core_camera.getPosition() or nil)
  lastExitStats = stats
end
local function cancelExit(reason)
  if not exitTransition then return end
  local state = exitTransition
  restoreExitDriverCamera(state)
  local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
  setWalkingCameraTransition(unicycle, nil)
  storeExitStats(reason or "cancel")
  exitTransition = nil
end

local function startExit(veh)
  if not isRealisticEntryEnabled() or not veh or gameplay_walk.isWalking() then return false end
  if not gameplay_walk.isAtParkingSpeed or not gameplay_walk.isAtParkingSpeed() then return false end
  if exitTransition or approach then return false end

  lastExitStats = nil
  postEnter = nil
  postExit = nil
  local doorInfo = findDriverDoorInfo(veh)
  local lockedDoorName = doorInfo and (doorInfo.triggerName or doorInfo.canonicalName) or nil
  local standPos, front, doorCenter, _, _, standMargin = getStandPos(
    veh, veh:getPosition(), lockedDoorName, 0, doorInfo
  )
  if not standPos then return false end
  requestCollisionEnvelope(veh, false)
  local standClearance = vehicleClearance2D(standPos, veh:getId(), 0)

  local targetCameraName = core_camera.getActiveCamNameByVehId(veh:getId()) or core_camera.getActiveCamName()
  local useDriverTransition = targetCameraName == "driver"
  local driverCam
  if useDriverTransition then
    local cameraData = core_camera.getCameraDataById(veh:getId())
    driverCam = cameraData and cameraData.driver
  end

  exitTransition = {
    vehId = veh:getId(),
    model = veh:getJBeamFilename(),
    t = 0,
    phaseT = 0,
    phase = "openDoor",
    standPos = vec3(standPos),
    front = front and vec3(front) or nil,
    doorSide = doorInfo and doorInfo.side,
    doorTriggerName = doorInfo and doorInfo.triggerName,
    doorControllerName = doorInfo and doorInfo.controllerName,
    doorReferenceSource = doorInfo and doorInfo.referenceSource,
    doorTriggerCenterValid = doorInfo and doorInfo.triggerCenterValid == true,
    doorTriggerLateral = doorInfo and doorInfo.triggerLateral,
    doorReferenceLateral = getLateralOffset(veh, doorCenter),
    doorReferenceLocal = doorCenter and worldPointToVehicleLocal(veh, doorCenter) or nil,
    doorInfo = doorInfo,
    doorCenter = doorCenter and vec3(doorCenter) or nil,
    maxDoorGap = 0,
    doorOpenElapsed = 0,
    doorProbeCount = 0,
    nextDoorProbeT = 0,
    standMargin = standMargin,
    standClearance = standClearance,
    targetCameraName = targetCameraName,
    useDriverTransition = useDriverTransition,
    driverCam = driverCam,
    driverYaw = driverCam and driverCam.relativeYaw or nil,
    driverPitch = driverCam and driverCam.relativePitch or nil,
    startCameraPos = vecToTable(core_camera.getPosition and core_camera.getPosition() or nil),
    lookDir = getCameraLookDir()
  }
  exitTransition.doorCommanded = ensureDoorState(
    veh, exitTransition.doorControllerName, true, "exit"
  )
  if not exitTransition.doorCommanded then
    exitTransition.doorControllerFound = false
  end
  guihooks.trigger("Message", {
    ttl = 3,
    msg = "Exiting vehicle...",
    category = "walkingmode",
    icon = "seatArrowOutRight"
  })
  return true
end

local function updateExit(dt)
  if not exitTransition then return end
  local state = exitTransition
  state.t = state.t + dt
  state.phaseT = state.phaseT + dt
  local veh = getObjectByID(state.vehId)
  if not veh then
    cancelExit("vehicleMissing")
    return
  end
  local referenceCenter = state.doorReferenceLocal
    and vehicleLocalPointToWorld(veh, state.doorReferenceLocal) or state.doorCenter
  if referenceCenter then state.doorCenter = vec3(referenceCenter) end
  local liveDoorCenter = state.doorTriggerName
    and getDoorTriggerCenter(veh, state.doorTriggerName) or nil
  local liveDoorCenterValid = liveDoorCenter
    and isDoorCenterOnSide(veh, liveDoorCenter, state.doorSide)
  if not liveDoorCenterValid then liveDoorCenter = nil end
  local doorCenter = liveDoorCenter or referenceCenter
  if state.phase == "openDoor" then
    state.doorOpenElapsed = (state.doorOpenElapsed or 0) + dt
    state.nextDoorProbeT = state.nextDoorProbeT or 0
    if state.doorControllerName and state.doorOpenElapsed >= state.nextDoorProbeT then
      ensureDoorState(veh, state.doorControllerName, true, "exit")
      state.doorProbeCount = (state.doorProbeCount or 0) + 1
      state.nextDoorProbeT = state.doorOpenElapsed + cfg.doorProbeInterval
    end
    local forceDuration = math.max(state.doorOpenForceDuration or 0.20, 0.08)
    local visualOpenTime = math.max(0.52, forceDuration + cfg.doorSwingSettle)
    local p = smoothstep01(state.doorOpenElapsed / visualOpenTime)
    if state.driverCam then
      local sideSign = state.doorSide == "R" and 1 or -1
      state.driverCam.relativeYaw = (state.driverYaw or 0) + sideSign * 0.38 * p
      state.driverCam.relativePitch = (state.driverPitch or 0) + 0.045 * p
    end
    if not isDoorOpenReady(state) then return end

    state.exitSwitchT = state.t
    restoreExitDriverCamera(state)
    local rot = state.front and quatFromDir(state.front, up) or nil
    originalSetWalkingMode(true, state.standPos, rot, true)
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    if not unicycle then
      cancelExit("unicycleMissing")
      return
    end
    if state.useDriverTransition then
      core_camera.setVehicleCameraByNameWithId(unicycle:getId(), "unicycle", false, {})
    end
    local target = getExitDoorLookPos(veh, doorCenter) or veh:getPosition()
    local toTarget = target - getLookOrigin(unicycle:getPosition())
    if toTarget:length() > 1e-3 then
      toTarget:normalize()
      state.lookDir = toTarget
      gameplay_walk.setRot(toTarget, up)
    end
    state.phase = "closeDoor"
    state.phaseT = 0
    return
  end

  if state.phase == "closeDoor" then
    local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
    if not unicycle then
      cancelExit("walkingInterrupted")
      return
    end
    local pos = unicycle:getPosition()
    local target = getExitDoorLookPos(veh, doorCenter) or veh:getPosition()
    local toTarget = target - getLookOrigin(pos)
    if toTarget:length() > 1e-3 then
      toTarget:normalize()
      state.lookDir = smoothLookDir(state.lookDir, toTarget, dt)
      gameplay_walk.setRot(state.lookDir, up)
    end
    if state.useDriverTransition then
      local settle = math.sin(math.pi * clamp(state.phaseT / 0.42, 0, 1))
      setWalkingCameraTransition(unicycle, {
        forward = 0.018 * settle,
        z = -0.012 * settle,
        pitch = 0.008 * settle
      })
    end
    if not state.closeCommanded and state.phaseT >= cfg.doorCloseDelay then
      state.closeCommanded = ensureDoorState(veh, state.doorControllerName, false, "exit")
      if not state.closeCommanded then state.doorClosed = state.doorControllerName == nil end
      state.closeCommandT = state.phaseT
      state.closeRetryCount = 0
      state.nextCloseRetryT = state.phaseT + getDoorCloseRetryInterval(state)
    end
    state.closeProbeCount = state.closeProbeCount or 0
    if state.closeCommanded and state.doorControllerName
      and state.closeProbeCount < 40
      and state.phaseT >= cfg.doorCloseDelay + cfg.doorProbeInterval * (state.closeProbeCount + 1) then
      ensureDoorState(veh, state.doorControllerName, false, "exit", true)
      state.closeProbeCount = state.closeProbeCount + 1
    end
    if state.closeCommanded and state.doorControllerName and not state.doorClosed
      and state.doorStateAfter ~= "broken"
      and state.phaseT >= (state.nextCloseRetryT or math.huge) then
      ensureDoorState(veh, state.doorControllerName, false, "exit")
      state.closeRetryCount = (state.closeRetryCount or 0) + 1
      state.nextCloseRetryT = state.phaseT + getDoorCloseRetryInterval(state)
    end
    local closeFinished = state.doorClosed == true and state.phaseT >= cfg.doorCloseFinish
    local closeHardLimit = math.max(
      cfg.doorCloseTimeout,
      (state.doorCloseForceDuration or 0.6) + 0.35
    )
    local closeTimedOut = state.phaseT >= closeHardLimit
    if closeFinished or closeTimedOut then
      setWalkingCameraTransition(unicycle, nil)
      storeExitStats("exit")
      if state.doorControllerName and not state.doorClosed then
        postExit = {
          vehId = state.vehId,
          controllerName = state.doorControllerName,
          doorControllerName = state.doorControllerName,
          doorControllerFound = state.doorControllerFound,
          doorClosed = state.doorClosed,
          doorOpened = state.doorOpened,
          doorGap = state.doorGap,
          maxDoorGap = state.maxDoorGap,
          doorPhysicalMeasured = state.doorPhysicalMeasured,
          doorOpenForceDuration = state.doorOpenForceDuration,
          doorCloseForceDuration = state.doorCloseForceDuration,
          doorOpenWait = state.doorOpenWait,
          doorFullyOpened = state.doorFullyOpened,
          doorFullEvidence = state.doorFullEvidence,
          doorOpenTimedOut = state.doorOpenTimedOut,
          t = 0,
          probeCount = 0,
          closeCommanded = true,
          closeRetryCount = state.closeRetryCount or 0,
          nextCloseRetryT = getDoorCloseRetryInterval(state)
        }
      end
      exitTransition = nil
    end
  end
end

local function updatePostExit(dt)
  if not postExit then return end
  postExit.t = postExit.t + dt
  local veh = getObjectByID(postExit.vehId)
  if not veh then
    postExit = nil
    return
  end
  if postExit.doorClosed then
    postExit = nil
    return
  end
  if postExit.probeCount < 70 and postExit.t >= 0.10 * (postExit.probeCount + 1) then
    ensureDoorState(veh, postExit.controllerName, false, "exit", true)
    postExit.probeCount = postExit.probeCount + 1
  end
  if postExit.doorStateAfter ~= "broken"
    and postExit.t >= (postExit.nextCloseRetryT or 0) then
    ensureDoorState(veh, postExit.controllerName, false, "exit")
    postExit.closeRetryCount = (postExit.closeRetryCount or 0) + 1
    postExit.nextCloseRetryT = postExit.t + getDoorCloseRetryInterval(postExit)
  end
  if postExit.t >= 7.0 then postExit = nil end
end

local function updatePostEnter(dt)
  if not postEnter then return end
  postEnter.t = postEnter.t + dt
  local veh = getObjectByID(postEnter.vehId)
  if not veh then
    postEnter = nil
    return
  end

  if not isDoorOpenReady(postEnter) then
    postEnter.doorOpenElapsed = (postEnter.doorOpenElapsed or 0) + dt
    postEnter.nextDoorProbeT = postEnter.nextDoorProbeT or 0
    if postEnter.controllerName and postEnter.doorOpenElapsed >= postEnter.nextDoorProbeT then
      ensureDoorState(veh, postEnter.controllerName, true, "entry")
      postEnter.doorProbeCount = (postEnter.doorProbeCount or 0) + 1
      postEnter.nextDoorProbeT = postEnter.doorOpenElapsed + cfg.doorProbeInterval
    end
    isDoorOpenReady(postEnter)
    copyDoorStats(lastApproachStats, postEnter)
    if not postEnter.doorOpenReady then return end
  end
  postEnter.openReadyPostT = postEnter.openReadyPostT or postEnter.t

  if not postEnter.closeCommanded
    and postEnter.t >= postEnter.openReadyPostT + cfg.doorCloseDelay then
    postEnter.closeCommanded = ensureDoorState(veh, postEnter.controllerName, false, "entry")
    if not postEnter.closeCommanded then postEnter.doorClosed = postEnter.controllerName == nil end
    postEnter.closeCommandT = postEnter.t
    postEnter.closeRetryCount = 0
    postEnter.nextCloseRetryT = postEnter.t + getDoorCloseRetryInterval(postEnter)
  end
  postEnter.closeProbeCount = postEnter.closeProbeCount or 0
  if postEnter.closeCommanded and postEnter.controllerName
    and postEnter.closeProbeCount < 60
    and postEnter.t >= (postEnter.closeCommandT or 0) + cfg.doorProbeInterval * (postEnter.closeProbeCount + 1) then
    ensureDoorState(veh, postEnter.controllerName, false, "entry", true)
    postEnter.closeProbeCount = postEnter.closeProbeCount + 1
  end
  if postEnter.closeCommanded and postEnter.controllerName and not postEnter.doorClosed
    and postEnter.doorStateAfter ~= "broken"
    and postEnter.t >= (postEnter.nextCloseRetryT or math.huge) then
    ensureDoorState(veh, postEnter.controllerName, false, "entry")
    postEnter.closeRetryCount = (postEnter.closeRetryCount or 0) + 1
    postEnter.nextCloseRetryT = postEnter.t + getDoorCloseRetryInterval(postEnter)
  end
  copyDoorStats(lastApproachStats, postEnter)
  local closedLongEnough = postEnter.doorClosed == true
    and postEnter.t >= (postEnter.closeCommandT or postEnter.t) + 0.10
  if closedLongEnough or postEnter.t >= 7.0 then postEnter = nil end
end

local function restoreWalkingWithoutPlayer(rot, requestName)
  local recoveryPos = lastPlayerPos or (core_camera.getPosition and core_camera.getPosition())
  if recoveryPos then
    log("W", "walkEnterVehicle", string.format(
      "%s had no player vehicle; restoring the unicycle at the last valid player position",
      requestName
    ))
    return originalSetWalkingMode(true, vec3(recoveryPos), rot, true)
  end
  log("E", "walkEnterVehicle", requestName .. " ignored because no player vehicle or recovery position exists")
  return false, nil
end

local function wrappedToggleWalkingMode()
  if exitTransition then
    cancelExit("cancel")
    guihooks.trigger("Message", {category = "walkingmode", clear = true})
    return
  end
  if approach then
    skipApproach("repeatToggle")
    return
  end

  if isRealisticEntryEnabled() and gameplay_walk.isWalking() then
    local veh = gameplay_walk.getVehicleInFront()
    if veh and startApproach(veh) then
      return
    end
  end

  if isRealisticEntryEnabled() and not gameplay_walk.isWalking() then
    local veh = getPlayerVehicle(0)
    if veh and startExit(veh) then return end
    if not veh then
      return restoreWalkingWithoutPlayer(nil, "Walking toggle")
    end
  end

  return originalToggle()
end

local function wrappedSetWalkingMode(enabled, pos, rot, force)
  if approach and not enabled and not force then
    local vehId = approach.vehId
    skipApproach("repeatSetWalkingMode")
    return true, vehId
  elseif approach and enabled then
    cancelApproach()
  end

  if exitTransition and not enabled then
    cancelExit("interrupted")
  end

  if isRealisticEntryEnabled() and enabled and not force and not pos and not gameplay_walk.isWalking() then
    local veh = getPlayerVehicle(0)
    if veh and startExit(veh) then return true, veh:getId() end
    if not veh then
      return restoreWalkingWithoutPlayer(rot, "Walking mode request")
    end
  end

  if isRealisticEntryEnabled() and not enabled and not force and gameplay_walk.isWalking() then
    local veh = gameplay_walk.getVehicleInFront()
    if veh and startApproach(veh) then
      local unicycle = gameplay_walk.getCurrentUnicycle()
      return true, unicycle and unicycle:getId()
    end
  end

  return originalSetWalkingMode(enabled, pos, rot, force)
end

local function wrappedSwitchCycleVehicle(player, dir)
  if gameplay_walk and gameplay_walk.isWalking() then
    if approach then
      skipApproach("repeatVehicleSwitch")
      return
    end
    if isRealisticEntryEnabled() then
      local veh = getNearestEnterableVehicle()
      if veh and gameplay_walk.isAtParkingSpeed() and startApproach(veh) then
        return
      end
    end
  elseif exitTransition then
    cancelExit("vehicleSwitch")
    return
  end
  return originalSwitchCycle(player, dir)
end

local function onUpdate(dtReal, dtSim)
  local playerVeh = getPlayerVehicle(0)
  if playerVeh then
    if lastPlayerPos then
      lastPlayerPos:set(playerVeh:getPosition())
    else
      lastPlayerPos = vec3(playerVeh:getPosition())
    end
  end
  local dt = dtSim or dtReal
  if not dt or dt <= 0 then return end
  updateDriverSettle(dt)
  updatePostEnter(dt)
  updatePostExit(dt)
  if exitTransition then
    if not isRealisticEntryEnabled() then
      cancelExit("disabled")
      return
    end
    updateExit(dt)
    return
  end
  if not approach then return end
  if not isRealisticEntryEnabled() then
    cancelApproach()
    return
  end
  local veh = getObjectByID(approach.vehId)
  local unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle() or nil
  local vehicleEnterable = isEnterableVehicle(veh)
  if not vehicleEnterable or not unicycle or not gameplay_walk.isWalking() then
    cancelApproach(not vehicleEnterable and "vehicleUnavailable" or "walkingInterrupted")
    return
  end

  local pos = unicycle:getPosition()
  local standPos, front, doorCenter = getStandPos(
    veh, pos, approach.doorName, approach.aftFactor, approach.doorInfo
  )
  local liveDoorCenter = approach.doorTriggerName
    and getDoorTriggerCenter(veh, approach.doorTriggerName) or nil
  local liveDoorCenterValid = liveDoorCenter
    and isDoorCenterOnSide(veh, liveDoorCenter, approach.doorSide)
  if not liveDoorCenterValid then liveDoorCenter = nil end
  if not standPos then
    finishEnter(veh)
    return
  end
  if approach.phase == "approach" then
    approach.standPos = standPos
  end
  approach.doorCenter = doorCenter or approach.doorCenter
  approach.vehRef = getVehicleRefPos(veh)
  approach.front = front
  local vehRef = approach.vehRef
  local vehLook = getVehicleLookPos(veh)
  local aftFactor = approach.aftFactor or 0
  if approach.boardDoorLocal then
    approach.boardDoorRef = vehicleLocalPointToWorld(veh, approach.boardDoorLocal)
  elseif doorCenter or approach.doorCenter then
    approach.boardDoorRef = vec3(doorCenter or approach.doorCenter)
    approach.boardDoorLocal = worldPointToVehicleLocal(veh, approach.boardDoorRef)
  end
  local boardLook = getBoardLookPos(veh, approach.boardDoorRef, aftFactor) or vehLook
  local boardGoal = getBoardTarget(veh, approach.boardDoorRef, aftFactor) or vehRef

  local goalPos = approach.standPos or standPos
  if approach.phase == "board" then
    goalPos = boardGoal or approach.boardTarget or vehRef or standPos
  end

  local dist = pos:distance(goalPos)
  local livePlayerLong = getLongitudinalOffset(veh, pos)
  local liveDoorLong = getLongitudinalOffset(
    veh, approach.boardDoorRef or doorCenter or approach.doorCenter
  )
  local liveSwingClearance = livePlayerLong and liveDoorLong
    and (livePlayerLong - liveDoorLong) * (approach.safeStandLongSign or -1)
    or nil
  local requiredSwingClearance = approach.doorControllerName
    and math.max(0.18, (approach.doorSpan or 0.60) * 0.25) or nil
  approach.finalDistance = dist
  approach.minDistance = math.min(approach.minDistance, dist)
  approach.maxDistance = math.max(approach.maxDistance, dist)
  approach.pathLength = approach.pathLength + approach.prevPos:distance(pos)
  approach.prevPos:set(pos)
  approach.t = approach.t + dt

  if approach.phase == "approach" and approach.collisionEscapeTarget then
    local escape = (approach.collisionEscapeTarget - pos):z0()
    local escapeDistance = escape:length()
    approach.collisionEscapeT = (approach.collisionEscapeT or 0) + dt
    if escapeDistance <= 0.10 or approach.t > cfg.approachTimeout then
      approach.collisionEscapeTarget = nil
      approach.collisionEscapeT = 0
      approach.route = nil
      approach.routeIndex = 1
      approach.waypoint = nil
      approach.stallWindowT = 0
      approach.stallWindowPath = approach.pathLength
      clearExternalMove(unicycle)
    else
      escape:normalize()
      lookAtVehicle(pos, vehLook, dt)
      setExternalMove(unicycle, escape.x, escape.y, 0)
      return
    end
  end

  -- Oversized tyres, tracks, and attachments can still trap the walking capsule
  -- after deformation. If the unicycle has made less than a
  -- walking step of progress over a full two-second window, stop grinding into
  -- the collision mesh and hand off to the door/boarding cinematic. This is most
  -- visible on the mining dump truck, but also keeps unusual mod vehicles usable.
  if approach.phase == "approach" then
    approach.stallWindowT = (approach.stallWindowT or 0) + dt
    if approach.stallWindowT >= cfg.stallWindow then
      local walked = approach.pathLength - (approach.stallWindowPath or 0)
      approach.stallWindowT = 0
      approach.stallWindowPath = approach.pathLength
      if approach.t >= cfg.stallWindow
        and walked < cfg.stallPath
        and dist <= math.max(8, (approach.startDistance or dist) + 1) then
        approach.phase = "waitDoor"
        approach.arrived = true
        approach.reachAssist = true
        approach.reachAssistDistance = dist
        approach.reachAssistReason = "stalled"
        approach.arriveT = 0
        approach.standPos = vec3(pos)
        approach.boardTarget = getBoardTarget(veh, approach.boardDoorRef, aftFactor)
        clearExternalMove(unicycle)
      end
    end
  end

  if approach.phase == "approach" and dist <= cfg.arrive
    and (not requiredSwingClearance or not liveSwingClearance
      or liveSwingClearance >= requiredSwingClearance) then
    approach.phase = "waitDoor"
    approach.arrived = true
    approach.arriveT = 0
    approach.standPos = standPos
    approach.boardTarget = getBoardTarget(veh, approach.boardDoorRef, aftFactor)
  end

  if approach.phase == "waitDoor" then
    if not approach.doorCommanded and approach.doorControllerName then
      local lockedDoorCenter = approach.boardDoorRef or doorCenter or approach.doorCenter
      local sideAligned, playerLateral, expectedLateral, selectedDoorLateral =
        getDriverDoorSideAlignment(veh, pos, approach.doorInfo, lockedDoorCenter)
      approach.doorCommandPlayerLateral = playerLateral
      approach.doorCommandExpectedLateral = expectedLateral
      approach.doorCommandSelectedDoorLateral = selectedDoorLateral
      approach.doorCommandSideAligned = sideAligned == true
      local playerLongitudinal = getLongitudinalOffset(veh, pos)
      local doorLongitudinal = getLongitudinalOffset(veh, lockedDoorCenter)
      approach.doorCommandPlayerLongitudinal = playerLongitudinal
      approach.doorCommandDoorLongitudinal = doorLongitudinal
      approach.doorCommandSwingClearance = playerLongitudinal and doorLongitudinal
        and (playerLongitudinal - doorLongitudinal) * (approach.safeStandLongSign or -1)
        or nil
      local swingAligned = not requiredSwingClearance
        or not approach.doorCommandSwingClearance
        or approach.doorCommandSwingClearance >= requiredSwingClearance
      if sideAligned == false or not swingAligned then
        approach.wrongSideCorrections = (approach.wrongSideCorrections or 0) + 1
        if not swingAligned then
          approach.swingClearanceCorrections = (approach.swingClearanceCorrections or 0) + 1
        end
        approach.phase = "approach"
        approach.arrived = false
        approach.reachAssist = false
        approach.reachAssistDistance = nil
        approach.reachAssistReason = nil
        approach.route = nil
        approach.routeIndex = 1
        approach.waypoint = nil
        approach.stallWindowT = 0
        approach.stallWindowPath = approach.pathLength
        approach.t = math.min(approach.t, cfg.approachTimeout - 3)
        clearExternalMove(unicycle)
        return
      end
    end
    approach.boardTarget = boardGoal and vec3(boardGoal) or approach.boardTarget
    approach.arriveT = (approach.arriveT or 0) + dt
    approach.doorOpenElapsed = (approach.doorOpenElapsed or 0) + dt
    if not approach.doorCommanded then
      if not approach.doorCommandT then
        approach.doorCommandT = approach.t
        approach.doorCommandStandDistance = pos:distance(approach.standPos or standPos)
        approach.doorCommandDoorDistance = (doorCenter or approach.doorCenter)
          and pos:distance(doorCenter or approach.doorCenter) or nil
        approach.doorCommandClearance = vehicleClearance2D(pos, approach.vehId, 0)
        local sideAligned, playerLateral, expectedLateral, selectedDoorLateral =
          getDriverDoorSideAlignment(
            veh, pos, approach.doorInfo, approach.boardDoorRef or doorCenter or approach.doorCenter
          )
        approach.doorCommandPlayerLateral = playerLateral
        approach.doorCommandExpectedLateral = expectedLateral
        approach.doorCommandSelectedDoorLateral = selectedDoorLateral
        approach.doorCommandSideAligned = sideAligned == true
        local lockedDoorCenter = approach.boardDoorRef or doorCenter or approach.doorCenter
        local playerLongitudinal = getLongitudinalOffset(veh, pos)
        local doorLongitudinal = getLongitudinalOffset(veh, lockedDoorCenter)
        approach.doorCommandPlayerLongitudinal = playerLongitudinal
        approach.doorCommandDoorLongitudinal = doorLongitudinal
        approach.doorCommandSwingClearance = playerLongitudinal and doorLongitudinal
          and (playerLongitudinal - doorLongitudinal) * (approach.safeStandLongSign or -1)
          or nil
      end
      approach.doorCommanded = ensureDoorState(
        veh, approach.doorControllerName, true, "entry"
      )
      if not approach.doorCommanded then approach.doorControllerFound = false end
      if approach.doorCommanded then
        approach.doorProbeCount = (approach.doorProbeCount or 0) + 1
        approach.nextDoorProbeT = approach.doorOpenElapsed + cfg.doorProbeInterval
      end
    end
    if approach.doorCommanded and approach.doorControllerName
      and approach.doorOpenElapsed >= (approach.nextDoorProbeT or 0) then
      ensureDoorState(veh, approach.doorControllerName, true, "entry")
      approach.doorProbeCount = (approach.doorProbeCount or 0) + 1
      approach.nextDoorProbeT = approach.doorOpenElapsed + cfg.doorProbeInterval
    end
    clearExternalMove(unicycle)
    local doorLook = getDoorLookPos(veh, liveDoorCenter or doorCenter or approach.doorCenter) or boardLook
    lookAtVehicle(pos, doorLook, dt)
    local forceDuration = math.max(approach.doorOpenForceDuration or 0.20, 0.08)
    local visualOpenTime = approach.doorControllerName
      and math.max(0.52, forceDuration + cfg.doorSwingSettle)
      or cfg.doorFallbackOpen
    local openP = clamp(approach.doorOpenElapsed / visualOpenTime, 0, 1)
    if approach.useDriverTransition then
      local reach = math.sin(math.pi * smoothstep01(openP))
      local sideSign = approach.doorSide == "R" and -1 or 1
      setWalkingCameraTransition(unicycle, {
        forward = 0.052 * reach,
        side = sideSign * 0.016 * reach,
        z = -0.020 * reach,
        pitch = 0.012 * reach,
        roll = sideSign * 0.010 * reach
      })
    end
    if isDoorOpenReady(approach) then
      approach.phase = "stepCloser"
      approach.entryCloseT = 0
      approach.entryCloseTravel = 0
      approach.entryClosePrevPos = vec3(pos)
      approach.entryClosePos = getDoorPocketPos(
        veh,
        approach.boardDoorRef or doorCenter or approach.doorCenter,
        approach.safeStandLongSign,
        approach.doorSpan,
        pos.z
      )
      approach.entryCloseStartDistance = approach.entryClosePos
        and pos:distance(approach.entryClosePos) or 0
      approach.entryCloseStartClearance = vehicleClearance2D(pos, approach.vehId, 0)
      approach.entryDoorHoldT = 0
      approach.route = nil
      approach.routeIndex = 1
      approach.waypoint = nil
      approach.prevBoardClearance = nil
      approach.prevRefDist = nil
    end
    return
  end

  if approach.phase == "stepCloser" then
    approach.entryCloseT = (approach.entryCloseT or 0) + dt
    holdEntryDoorOpen(veh, dt)
    local closeGoal = getDoorPocketPos(
      veh,
      approach.boardDoorRef or doorCenter or approach.doorCenter,
      approach.safeStandLongSign,
      approach.doorSpan,
      pos.z
    ) or approach.entryClosePos
    approach.entryClosePos = closeGoal
    if not closeGoal then
      approach.entryCloseCompleted = false
      approach.phase = "stepIn"
      approach.entryStepT = 0
      approach.entryStepTravel = 0
      approach.entryStepPrevPos = vec3(pos)
      return
    end

    if approach.entryClosePrevPos then
      approach.entryCloseTravel = (approach.entryCloseTravel or 0)
        + approach.entryClosePrevPos:distance(pos)
      approach.entryClosePrevPos:set(pos)
    end
    local closeDistance = pos:distance(closeGoal)
    approach.entryCloseFinalDistance = closeDistance
    local closeClearance, envelopeSource, collisionHull, collisionEnvelope = vehicleClearance2D(
      pos, approach.vehId, 0
    )
    noteCollisionEnvelope(approach, envelopeSource, collisionHull, collisionEnvelope)
    approach.entryCloseTargetClearance = vehicleClearance2D(closeGoal, approach.vehId, 0)
    local closeP = smoothstep01(clamp(
      1 - closeDistance / math.max(approach.entryCloseStartDistance or closeDistance, 0.1), 0, 1
    ))
    local closeLook = getDoorLookPos(veh, liveDoorCenter or doorCenter or approach.doorCenter)
      or boardLook
    local closeForward = boardingCamera.getForwardDir(veh)
    if approach.useDriverTransition and closeP >= 0.50 and closeForward then
      boardingCamera.lookInDirection(closeForward, dt, true)
    else
      lookAtVehicle(pos, closeLook, dt)
    end
    if approach.useDriverTransition then
      local sideSign = approach.doorSide == "R" and -1 or 1
      setWalkingCameraTransition(unicycle, {
        forward = 0.020 * closeP,
        side = sideSign * 0.008 * closeP,
        z = -0.012 * closeP,
        pitch = 0.008 * closeP,
        roll = sideSign * 0.005 * closeP
      })
    end
    local reached = closeDistance <= 0.10
    local timedOut = approach.entryCloseT >= 1.80
    if reached or timedOut then
      approach.entryCloseCompleted = reached
      approach.phase = "stepSettle"
      approach.entrySettleT = 0
      approach.entryStepT = 0
      approach.entryStepTravel = 0
      approach.entryStepPrevPos = vec3(pos)
      approach.entryStepPos = getDoorEntryPos(
        veh, approach.boardDoorRef or doorCenter or approach.doorCenter, pos.z
      )
      approach.entryStepStartDistance = approach.entryStepPos
        and pos:distance(approach.entryStepPos) or 0
      if approach.entryStepPos then
        local plannedDelta = (approach.entryStepPos - (approach.entryClosePos or pos)):z0()
        local plannedFwd = veh:getDirectionVector():z0()
        if plannedFwd:length() > 1e-4 then plannedFwd:normalize() end
        local plannedLeft = veh:getDirectionVectorUp():cross(plannedFwd):z0()
        if plannedLeft:length() > 1e-4 then plannedLeft:normalize() end
        approach.entryStepPlannedLongitudinal = math.abs(plannedDelta:dot(plannedFwd))
        approach.entryStepPlannedLateral = math.abs(plannedDelta:dot(plannedLeft))
      end
      clearExternalMove(unicycle)
      return
    end

    local toClose = (closeGoal - pos):z0()
    if toClose:length() > 1e-4 then
      local closeMoveScale = clamp((toClose:length() / 0.30) ^ 2, 0.10, 1)
      toClose:normalize()
      setExternalMove(
        unicycle, toClose.x * closeMoveScale, toClose.y * closeMoveScale, 0
      )
    else
      clearExternalMove(unicycle)
    end
    return
  end

  if approach.phase == "stepSettle" then
    approach.entrySettleT = (approach.entrySettleT or 0) + dt
    holdEntryDoorOpen(veh, dt)
    clearExternalMove(unicycle)
    local settleLook = getDoorLookPos(veh, liveDoorCenter or doorCenter or approach.doorCenter)
      or boardLook
    local settleForward = boardingCamera.getForwardDir(veh)
    if approach.useDriverTransition and settleForward then
      -- Turn the head toward the road during the planted beat, before the body
      -- starts crossing the doorway. This prevents high seats from pulling the
      -- gaze up toward the seat during step-in.
      boardingCamera.lookInDirection(settleForward, dt, true)
    else
      lookAtVehicle(pos, settleLook, dt)
    end
    if approach.entrySettleT >= 0.18 then
      approach.phase = "stepIn"
      approach.route = nil
      approach.routeIndex = 1
      approach.waypoint = nil
    end
    return
  end

  if approach.phase == "stepIn" then
    approach.entryStepT = (approach.entryStepT or 0) + dt
    holdEntryDoorOpen(veh, dt)
    -- The live trigger follows the swung panel. Use the locked, closed-door
    -- reference so this target stays in the doorway between panel and body.
    local stepGoal = getDoorEntryPos(
      veh, approach.boardDoorRef or doorCenter or approach.doorCenter, pos.z
    )
      or approach.entryStepPos
    approach.entryStepPos = stepGoal
    if not stepGoal then
      approach.entryStepCompleted = false
      approach.phase = "board"
      approach.boardT = 0
      return
    end

    if approach.entryStepPrevPos then
      approach.entryStepTravel = (approach.entryStepTravel or 0)
        + approach.entryStepPrevPos:distance(pos)
      approach.entryStepPrevPos:set(pos)
    end
    local stepDistance = pos:distance(stepGoal)
    approach.entryStepFinalDistance = stepDistance
    local stepClearance, envelopeSource, collisionHull, collisionEnvelope = vehicleClearance2D(
      pos, approach.vehId, 0
    )
    noteCollisionEnvelope(approach, envelopeSource, collisionHull, collisionEnvelope)
    approach.entryStepTargetClearance = vehicleClearance2D(stepGoal, approach.vehId, 0)
    local stepP = smoothstep01(clamp(
      1 - stepDistance / math.max(approach.entryStepStartDistance or stepDistance, 0.1), 0, 1
    ))
    local stepLook = getBoardLookPos(veh, doorCenter or approach.doorCenter, aftFactor)
      or boardLook
    local forwardDir = boardingCamera.getForwardDir(veh)
    if approach.useDriverTransition and forwardDir then
      boardingCamera.lookInDirection(forwardDir, dt, true)
    else
      lookAtVehicle(pos, stepLook, dt)
    end
    if approach.useDriverTransition then
      local sideSign = approach.doorSide == "R" and -1 or 1
      setWalkingCameraTransition(unicycle, {
        forward = 0.045 * stepP,
        side = sideSign * 0.012 * stepP,
        z = -0.010 * stepP,
        pitch = 0,
        roll = sideSign * 0.008 * stepP
      })
    end
    local reached = stepDistance <= cfg.entryStepArrive
    local stepTimeout = approach.model == "nine" and 2.30 or cfg.entryStepTimeout
    local timedOut = approach.entryStepT >= stepTimeout
    if reached or timedOut then
      approach.entryStepCompleted = reached
      approach.doorwayBoard = reached or stepDistance <= 0.24
      approach.phase = "board"
      approach.boardT = 0
      approach.prevBoardClearance = nil
      approach.prevRefDist = nil
      clearExternalMove(unicycle)
      return
    end

    local stepMoveGoal = stepGoal
    if approach.model == "nine" then
      stepMoveGoal = getSteerTarget(
        pos, stepGoal, approach.vehId, 0.42, 0.04
      ) or stepGoal
    end
    local toStep = (stepMoveGoal - pos):z0()
    if toStep:length() > 1e-4 then
      local moveScale = approach.model == "nine"
        and clamp(stepDistance / 0.52, 0.32, 1) or 1
      toStep:normalize()
      setExternalMove(unicycle, toStep.x * moveScale, toStep.y * moveScale, 0)
    else
      clearExternalMove(unicycle)
    end
    return
  end

  if approach.phase == "board" then
    approach.boardT = (approach.boardT or 0) + dt
    approach.boardTarget = boardGoal and vec3(boardGoal) or approach.boardTarget
    if not boardGoal then
      finishEnter(veh)
      return
    end
    local clr, envelopeSource, collisionHull, collisionEnvelope = vehicleClearance2D(
      pos, approach.vehId, 0
    )
    noteCollisionEnvelope(approach, envelopeSource, collisionHull, collisionEnvelope)
    if envelopeSource ~= "none" then
      approach.minClearance = math.min(approach.minClearance or math.huge, clr)
      approach.maxClearance = math.max(approach.maxClearance or -math.huge, clr)
      approach.insideHits = (approach.insideHits or 0) + (clr < 0 and 1 or 0)
    end

    local refDist = pos:distance(boardGoal)
    local vel = unicycle:getVelocity()
    local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
    local refProgress = (approach.prevRefDist or refDist) - refDist
    approach.prevRefDist = refDist

    local boardP = clamp(approach.boardT / cfg.boardDuration, 0, 1)
    local cameraOnlyBoard = approach.reachAssist or approach.doorwayBoard
    local assistP = cameraOnlyBoard and smoothstep01(boardP) or 0
    local lookOrigin = getLookOrigin(pos)
    local forwardDir = boardingCamera.getForwardDir(veh)
    local driverCameraPos = boardingCamera.getDriverWorldPos(veh, approach.driverNodeId)
    if approach.useDriverTransition and not approach.boardStartCameraPos then
      approach.boardStartCameraPos = vec3(lookOrigin)
      approach.boardTargetCameraPos = driverCameraPos and vec3(driverCameraPos)
        or vec3(boardLook)
      approach.seatHeightDelta = approach.boardTargetCameraPos.z
        - approach.boardStartCameraPos.z
      approach.boardingVerticalMode = approach.seatHeightDelta > boardingCamera.highSeatThreshold
        and "high" or approach.seatHeightDelta < boardingCamera.lowSeatThreshold
        and "low" or "level"
    elseif driverCameraPos then
      -- Follow the exact driver camera node if the vehicle settles or moves.
      approach.boardTargetCameraPos = vec3(driverCameraPos)
    end

    local desiredCameraPos
    if approach.useDriverTransition and approach.boardStartCameraPos
      and approach.boardTargetCameraPos then
      local startCamera = approach.boardStartCameraPos
      local targetCamera = approach.boardTargetCameraPos
      desiredCameraPos = startCamera + (targetCamera - startCamera) * assistP

      -- Reach seat height early enough to express the direction of travel, then
      -- settle back onto the real driver-camera endpoint. Low seats dip and
      -- recover; high seats crest and drop. Neither curve changes the endpoint.
      local verticalSettleStart = 0.72
      if boardP <= verticalSettleStart then
        local verticalP = smoothstep01(boardP / verticalSettleStart)
        desiredCameraPos.z = startCamera.z
          + (targetCamera.z - startCamera.z) * verticalP
      else
        local settleP = clamp(
          (boardP - verticalSettleStart) / (1 - verticalSettleStart), 0, 1
        )
        local settleArc = math.sin(math.pi * settleP)
        settleArc = settleArc * settleArc
        if approach.boardingVerticalMode == "low" then
          desiredCameraPos.z = targetCamera.z - 0.045 * settleArc
        elseif approach.boardingVerticalMode == "high" then
          desiredCameraPos.z = targetCamera.z + 0.055 * settleArc
        else
          desiredCameraPos.z = targetCamera.z
        end
      end

      local baseCameraPos = boardingCamera.getWalkingBasePos(unicycle) or lookOrigin
      local worldOffset = desiredCameraPos - baseCameraPos
      setWalkingCameraTransition(unicycle, {
        worldX = worldOffset.x,
        worldY = worldOffset.y,
        worldZ = worldOffset.z,
        pitch = 0,
        roll = 0,
        yaw = 0
      })
    end

    if approach.useDriverTransition and forwardDir then
      boardingCamera.lookInDirection(forwardDir, dt, true)
    end
    if approach.useDriverTransition and approach.boardTargetCameraPos then
      approach.boardCameraEndpointError = lookOrigin:distance(approach.boardTargetCameraPos)
    end

    local endpointReached = not approach.useDriverTransition
      or not cameraOnlyBoard
      or (boardP >= 1 and (approach.boardCameraEndpointError or math.huge) <= 0.075)
    approach.boardCameraEndpointReached = endpointReached
    local collided = clr <= cfg.boardCollision
    local stalled = approach.boardT > 0.4
      and refDist < cfg.boardStall
      and refProgress < 0.025
      and speed < 0.55
    if approach.boardT >= cfg.boardTimeout
      or (boardP >= 1 and endpointReached)
      or (not cameraOnlyBoard and (collided or stalled)) then
      finishEnter(veh)
      return
    end
    if cameraOnlyBoard then
      -- The camera traverses the remaining gap all the way to the configured
      -- driver viewpoint while the walking capsule stays safely outside.
      clearExternalMove(unicycle)
      return
    end
    local toBoard = (boardGoal - pos):z0()
    if toBoard:length() < 1e-3 then
      finishEnter(veh)
      return
    end
    local moveDir = toBoard:normalized()
    lookAtVehicle(pos, boardLook, dt)
    setExternalMove(unicycle, moveDir.x, moveDir.y, 0)
    return
  end

  if approach.t > cfg.approachTimeout then
    approach.phase = "waitDoor"
    approach.arrived = true
    approach.reachAssist = true
    approach.reachAssistDistance = dist
    approach.reachAssistReason = "timeoutGuarantee"
    approach.arriveT = 0
    approach.doorOpenElapsed = 0
    approach.standPos = vec3(pos)
    approach.boardTarget = getBoardTarget(veh, approach.boardDoorRef, aftFactor)
    clearExternalMove(unicycle)
    return
  end

  local target = getSteerTarget(pos, approach.standPos or standPos, approach.vehId)
  local toTarget = (target - pos):z0()
  if toTarget:length() < 1e-3 then
    toTarget = ((approach.standPos or standPos) - pos):z0()
  end
  if toTarget:length() < 1e-3 then
    approach.phase = "waitDoor"
    approach.arrived = true
    approach.arriveT = 0
    clearExternalMove(unicycle)
    lookAtVehicle(pos, vehLook, dt)
    return
  end
  local moveDir = toTarget:normalized()
  local actualLook = getCameraLookDir() or approach.lookDir or moveDir
  local vel = unicycle:getVelocity()
  local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
  if speed < 15 then
    approach.speedSum = approach.speedSum + speed
    approach.speedSamples = approach.speedSamples + 1
    approach.maxSpeed = math.max(approach.maxSpeed, speed)
  end

  local lookOrigin = getLookOrigin(pos)
  local focusPos = vehLook
  local liveDoorLook = getDoorLookPos(veh, doorCenter or approach.doorCenter)
  if focusPos and liveDoorLook then
    local doorFocus = smoothstep01(clamp(1 - dist / 8, 0, 1))
    focusPos = focusPos * (1 - doorFocus) + liveDoorLook * doorFocus
  end
  local toVeh = focusPos and (focusPos - lookOrigin) or nil
  if toVeh and toVeh:length() > 1e-3 then
    toVeh:normalize()
  else
    toVeh = moveDir
  end
  local clr, envelopeSource, collisionHull, collisionEnvelope = vehicleClearance2D(
    pos, approach.vehId, 0
  )
  noteCollisionEnvelope(approach, envelopeSource, collisionHull, collisionEnvelope)
  if envelopeSource ~= "none" and clr <= cfg.boardCollision and dist > cfg.arrive then
    -- A rear/corner approach can graze the body before reaching the door-side
    -- waypoint. Move smoothly back outside the routing margin and rebuild; a
    -- collision here must never be treated as permission to open the door.
    local corrected = pushOutsideVehicle2D(
      pos, approach.vehId, cfg.routeMargin + 0.16
    )
    approach.collisionRecoveryCount = (approach.collisionRecoveryCount or 0) + 1
    approach.collisionEscapeTarget = corrected
    approach.collisionEscapeT = 0
    approach.route = nil
    approach.routeIndex = 1
    approach.waypoint = corrected
    local escape = (corrected - pos):z0()
    if escape:length() > 1e-4 then
      escape:normalize()
      setExternalMove(unicycle, escape.x, escape.y, 0)
    else
      clearExternalMove(unicycle)
    end
    lookAtVehicle(pos, liveDoorLook or vehLook, dt)
    return
  end
  local nearFactor = clamp(1 - dist / 7, 0, 1)
  nearFactor = nearFactor * nearFactor
  local vehBias = 0.55 + 0.35 * nearFactor
  local lookTarget = moveDir * (1 - vehBias) + toVeh * vehBias
  if lookTarget:length() < 1e-3 then lookTarget = toVeh else lookTarget:normalize() end
  approach.lookDir = smoothLookDir(approach.lookDir, lookTarget, dt)
  gameplay_walk.setRot(approach.lookDir, up)

  local approachSpeedCoef = approach.speedCoef or 0
  if dist < 1.6 then
    approachSpeedCoef = approachSpeedCoef * clamp((dist - cfg.arrive) / (1.6 - cfg.arrive), 0, 1)
  end
  setExternalMove(unicycle, moveDir.x, moveDir.y, approachSpeedCoef)

  if envelopeSource ~= "none" then
    approach.minClearance = math.min(approach.minClearance or math.huge, clr)
    approach.maxClearance = math.max(approach.maxClearance or -math.huge, clr)
    approach.insideHits = (approach.insideHits or 0) + (clr < 0 and 1 or 0)
  end

  local lookFlat = actualLook:z0()
  if lookFlat:length() > 1e-4 then lookFlat:normalize() else lookFlat = moveDir end
  local lookMoveDot = clamp(lookFlat:dot(moveDir), -1, 1)
  local lookVehDot = clamp(actualLook:dot(toVeh), -1, 1)
  if approach.t >= 0.3 then
    approach.lookMoveDotSum = approach.lookMoveDotSum + lookMoveDot
    approach.lookCarDotSum = approach.lookCarDotSum + lookVehDot
    approach.lookSamples = approach.lookSamples + 1
    approach.minLookMoveDot = math.min(approach.minLookMoveDot, lookMoveDot)
    local lookTurn = angleDeg(approach.prevActualLook, actualLook) or 0
    approach.totalLookTurnDeg = approach.totalLookTurnDeg + lookTurn
    approach.maxLookRateDeg = math.max(approach.maxLookRateDeg, lookTurn / math.max(dt, 1e-4))
    approach.maxCameraTargetErrorDeg = math.max(
      approach.maxCameraTargetErrorDeg,
      angleDeg(actualLook, approach.lookDir) or 0
    )
  end
  approach.prevActualLook = vec3(actualLook)
end

local function onVehicleSwitched(oldId, newId, player)
  if player == 0 and approach then
    cancelApproach()
  end
  -- Do not eagerly rebuild the collision envelope here. Part and tuning
  -- previews re-enter the replaced player vehicle and can fire this hook for
  -- every click. Entry/exit already request the envelope on demand and have an
  -- OBB fallback while the vehicle VM responds.
end

local function onVehicleSpawned(vehId)
  collisionEnvelopes[vehId] = nil
end

local function onVehicleDestroyed(vehId)
  collisionEnvelopes[vehId] = nil
end

local function installHooks()
  if not originalToggle and gameplay_walk then
    originalToggle = gameplay_walk.toggleWalkingMode
    originalSetWalkingMode = gameplay_walk.setWalkingMode
    gameplay_walk.toggleWalkingMode = wrappedToggleWalkingMode
    gameplay_walk.setWalkingMode = wrappedSetWalkingMode
  end

  if not originalSwitchCycle and core_input_vehicleSwitching then
    originalSwitchCycle = core_input_vehicleSwitching.switchCycleVehicle
    core_input_vehicleSwitching.switchCycleVehicle = wrappedSwitchCycleVehicle
  end
end

local function onExtensionLoaded()
  installHooks()
end

local function onExtensionUnloaded()
  cancelApproach()
  cancelExit("extensionUnload")
  postEnter = nil
  postExit = nil
  collisionEnvelopes = {}
  if driverSettle then
    restoreDriverCamera(driverSettle)
    driverSettle = nil
  end
  if originalToggle and gameplay_walk then
    gameplay_walk.toggleWalkingMode = originalToggle
    gameplay_walk.setWalkingMode = originalSetWalkingMode
  end
  originalToggle = nil
  originalSetWalkingMode = nil

  if originalSwitchCycle and core_input_vehicleSwitching then
    core_input_vehicleSwitching.switchCycleVehicle = originalSwitchCycle
  end
  originalSwitchCycle = nil
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed

M.notePlayerMove = notePlayerMove
M.noteDoorState = noteDoorState
M.startApproach = startApproach
M.startExit = startExit
M.cancelApproach = cancelApproach
M.getClosestDoorName = getClosestDoorName
M.getDriverDoorInfo = findDriverDoorInfo
M.getDoorTriggerCenter = getDoorTriggerCenter
M.getVehicleRefPos = getVehicleRefPos
M.getStandPos = getStandPos
M.getDoorEntryPos = getDoorEntryPos
M.getDoorPocketPos = getDoorPocketPos
M.receiveCollisionEnvelope = receiveCollisionEnvelope
M.getLastApproachStats = function() return lastApproachStats end
M.getLastExitStats = function() return lastExitStats end

return M
