-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_missions_missions', 'gameplay_missions_missionManager','freeroam_bigMapMode', 'gameplay_playmodeMarkers', 'freeroam_bigMapPoiProvider','ui_missionInfo'}

local skipIconFading = false
-- detect player velocity
local lastPosition = vec3(0,0,0)
local lastVel
local tmpVec = vec3()
local garageBorderClr = {1,0.5,0.5}
local forceReevaluateOpenPrompt = true
local markersVisibleTemporary = true

local vel = vec3()
local function getVelocity(dtSim, position)
  if not position then return 0 end
  lastVel = lastVel or 10

  if dtSim > 0 then
    vel:setSub2(position, lastPosition)
    lastVel = vel:length() / dtSim
  end
  lastPosition:set(position)
  return lastVel
end

local function inverseLerp(min, max, value)
 if math.abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end


local atParkingSpeed, atParkingSpeedPrev
local parkingSpeedMin, parkingSpeedMax = 1/3.6, 3/3.6
local function getParkingSpeedFactor(playerVelocity)
  if playerVelocity < parkingSpeedMin then atParkingSpeed =  true end
  if playerVelocity > parkingSpeedMax then atParkingSpeed = false end
  if atParkingSpeed == nil    then atParkingSpeed = playerVelocity < parkingSpeedMin end
  local atParkingSpeedChanged = atParkingSpeed ~= atParkingSpeedPrev
  atParkingSpeedPrev = atParkingSpeed
  return clamp(inverseLerp(parkingSpeedMin*1.25, parkingSpeedMin*0.75, playerVelocity),0,1), atParkingSpeed, atParkingSpeedChanged
end

local atCruisingSpeed, atCruisingSpeedPrev
local CruisingSpeedMin, CruisingSpeedMax = 20/3.6, 30/3.6
local function getCruisingSpeedFactor(playerVelocity)
  if playerVelocity < CruisingSpeedMin then atCruisingSpeed =  false end
  if playerVelocity > CruisingSpeedMax then atCruisingSpeed = true end
  if atCruisingSpeed == nil    then atCruisingSpeed = playerVelocity > CruisingSpeedMin end
  local atCruisingSpeedChanged = atCruisingSpeed ~= atCruisingSpeedPrev
  atCruisingSpeedPrev = atCruisingSpeed
  return (atCruisingSpeed and 1 or 0), atCruisingSpeed, atCruisingSpeedChanged
end


local currentInteractableElements = {}
local cachedInteractablePromptKey = nil
-- Brief pause after reaching parking speed so the driver can set park/parking brake
-- before ActivityStart steals B/Circle for Close.
local PROMPT_SETTLE_DELAY = 0.65
local pendingPromptElements = nil
local pendingPromptKey = nil
local promptSettleTimer = nil

local function clearPendingPrompt()
  pendingPromptElements = nil
  pendingPromptKey = nil
  promptSettleTimer = nil
end

local function getCurrentInteractableElements()
  return currentInteractableElements
end
M.getCurrentInteractableElements = getCurrentInteractableElements

M.formatMission = function(m)
  local info = {
    id = m.id,
    name = m.name,
    description = m.description,
    preview = m.previewFile,
    missionTypeLabel = m.missionTypeLabel or mission.missionType,
    userSettings = m:getUserSettingsData() or {},
    defaultUserSettings = m.defaultUserSettings or {},
    additionalAttributes = {},
    progress = m.saveData.progress,
    currentProgressKey = m.currentProgressKey or m.defaultProgressKey,
    unlocks = gameplay_missions_unlocks.constructUnlocksField(m),
    hasUserSettingsUnlocked = gameplay_missions_progress.missionHasUserSettingsUnlocked(m.id),
    devMission = m.devMission,
    tutorialActive = (career_career.isActive() and career_modules_tutorial.isActive()) or nil,
  }

  info.hasUserSettings = #info.userSettings > 0
  local additionalAttributes, additionalAttributesSortedKeys = gameplay_missions_missions.getAdditionalAttributes()

  for _, attKey in ipairs(additionalAttributesSortedKeys) do
    local att = additionalAttributes[attKey]
    local mAttKey = m.additionalAttributes[attKey]
    local val
    if type(mAttKey) == 'string' then
      val = att.valuesByKey[m.additionalAttributes[attKey]]
    elseif type(mAttKey) == 'table' then
      val = m.additionalAttributes[attKey]
    end
    if val then
      table.insert(info.additionalAttributes, {
        icon = att.icon or "",
        labelKey = att.translationKey,
        valueKey = val.translationKey
      })
    end
  end
  for _, customAtt in ipairs(m.customAdditionalAttributes or {}) do
    table.insert(info.additionalAttributes, customAtt)
  end
  info.formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id)
  info.leaderboardKey = m.defaultLeaderboardKey or 'recent'

  --info.gameContextUiButtons = {}
  info.gameContextUiButtons = m.getGameContextUiButtons and m:getGameContextUiButtons()
  return info
end
M.formatDataForUi = function()
  if not M.isStateWithPlaymodeMarkers() then return nil end
  local dataToSend = {}
  if not currentInteractableElements then return end
  for _, m in ipairs(currentInteractableElements or {}) do
    if m.missionId then
      table.insert(dataToSend, M.formatMission(gameplay_missions_missions.getMissionById(m.missionId)))
    end
  end
  table.sort(dataToSend, gameplay_missions_unlocks.depthIdSort)

  return dataToSend
end

M.startMissionById = function(id, userSettings, startingOptions)
log("E","","Deprecated startMissionById")
  print(debug.tracesimple())
end

M.stopMissionById = function(id, force)
  log("E","","Deprecated stopMissionById")
  print(debug.tracesimple())
end

M.changeUserSettings = function(id, settings)
  log("E","","Deprecated changeUserSettings")
  print(debug.tracesimple())
end

local preselectedMissionId = nil
M.setPreselectedMissionId = function(mId)
  preselectedMissionId = mId
end


local function getGameContext(fromMissionMenu)
  return gameplay_missions_missionScreen.getMissionScreenData()
end
M.getGameContext = getGameContext


local promptData = {}

local sortActivityData = function(a, b)
  -- Check if elements have a sorting table
  local hasSortingA = a.sorting ~= nil
  local hasSortingB = b.sorting ~= nil

  if hasSortingA and not hasSortingB then
    return true
  elseif not hasSortingA and hasSortingB then
    return false
  elseif hasSortingA and hasSortingB then
    -- Both have a sorting table; prioritize by type
    if a.sorting.type == "mission" and b.sorting.type ~= "mission" then
      return true
    elseif a.sorting.type ~= "mission" and b.sorting.type == "mission" then
      return false
    elseif a.sorting.type ~= b.sorting.type then
      return a.sorting.type < b.sorting.type
    else
      -- Same type; sort by order
      if (a.sorting.order or 0) == (b.sorting.order or 0) then
        return (a.sorting.id or a.heading) < (b.sorting.id or b.heading)
      end
      return (a.sorting.order or 0) < (b.sorting.order or 0)
    end
  else
    -- Neither have a sorting table; sort by heading
    return (a.heading or "") < (b.heading or "")
  end
end

-- ActivityStart Confirm (RB+Y / gameplay_interact) loses to vehicle-specific
-- chords like *__toggleFrontDiff on the same buttons. Only filter those
-- conflicts so camera / VehicleCommon / VehicleSpecific stay usable.
local ACTIVITY_PROMPT_FILTER = "rlsActivityPromptInput"
local activityPromptInputLocked = false

local function collectConflictingVehicleActions()
  local conflicting = {}
  if not (core_input_actions and core_input_actions.getActiveActions) then
    return conflicting
  end
  local actions = core_input_actions.getActiveActions()
  if type(actions) ~= "table" then
    return conflicting
  end
  for name, _ in pairs(actions) do
    if type(name) == "string" and name:find("__toggleFrontDiff", 1, true) then
      conflicting[#conflicting + 1] = name
    end
  end
  return conflicting
end

local function unlockActivityPromptInput()
  if not activityPromptInputLocked then return end
  activityPromptInputLocked = false
  if core_input_actionFilter then
    core_input_actionFilter.addAction(0, ACTIVITY_PROMPT_FILTER, false)
    core_input_actionFilter.setGroup(ACTIVITY_PROMPT_FILTER, {})
  end
end

local function lockActivityPromptInput()
  if activityPromptInputLocked then return end
  if not core_input_actionFilter then return end

  local blocked = collectConflictingVehicleActions()
  if #blocked == 0 then return end

  activityPromptInputLocked = true
  core_input_actionFilter.setGroup(ACTIVITY_PROMPT_FILTER, blocked)
  core_input_actionFilter.addAction(0, ACTIVITY_PROMPT_FILTER, true)
end

local function openViewDetailPrompt(elemData)
  local activityData = {}
  extensions.hook("onActivityAcceptGatherData", elemData, activityData)

  table.sort(activityData, sortActivityData)
  --for _, a in ipairs(activityData) do
  --  dump(a.heading, (a.sorting and a.sorting.type) or "no type", a.sorting)
  --end
  ui_missionInfo.openActivityAcceptDialogue(activityData)
  --guihooks.trigger('ActivityAcceptUpdate', activityData)
  -- Indeed-style Market Watch advert while engaging career work markers
  if career_career and career_career.isActive and career_career.isActive()
      and career_modules_activityHeat and career_modules_activityHeat.maybeShowOpportunityAdvert then
    local ok, err = pcall(career_modules_activityHeat.maybeShowOpportunityAdvert, "marker")
    if not ok then
      log("E", "markerInteraction", "maybeShowOpportunityAdvert failed: " .. tostring(err))
    end
  end

  if activityData and #activityData > 0 then
    lockActivityPromptInput()
  else
    unlockActivityPromptInput()
  end
end

local function onSelectDetailPromptClicked(idx)
  unlockActivityPromptInput()
  ui_missionInfo.closeDialogue()
  guihooks.trigger('ActivityAcceptUpdate', nil)
  local prompt = promptData[idx]
  if prompt and prompt.buttonFun then
    prompt.buttonFun()
  end
  table.clear(promptData)
end
M.onSelectDetailPromptClicked = onSelectDetailPromptClicked


local function closeViewDetailPrompt(force)
  if force then
    unlockActivityPromptInput()
    ui_missionInfo.closeDialogue()
    guihooks.trigger("onMissionAvailabilityChanged", {missionCount = 0})
    guihooks.trigger('ActivityAcceptUpdate', nil)
    extensions.hook("onMissionAvailabilityChanged", {missionCount = 0})
  end
end

local function onMissionInfoChangedState(fromState, toState)
  if toState == "closed" then
    unlockActivityPromptInput()
  elseif toState == "opened" then
    lockActivityPromptInput()
  end
end
M.onMissionInfoChangedState = onMissionInfoChangedState

local function openPromptFromElements(elements, promptKey)
  table.clear(currentInteractableElements)
  for i, elem in ipairs(elements) do
    currentInteractableElements[i] = elem
  end
  openViewDetailPrompt(elements)
  cachedInteractablePromptKey = promptKey
end

local screenWidth, screenHeight, screenRatio = 1,1,1
local function onSettingsChanged()
  local vm = GFXDevice.getVideoMode()
  screenWidth = vm.width
  screenHeight = vm.height
  screenRatio = screenWidth / screenHeight
end
M.onSettingsChanged = onSettingsChanged

local p1, p2, p3, p4, p5, p6, p7, p8 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local bbPoints = {}
local function getBBPoints(bbCenter, bbAxis0, bbAxis1, bbAxis2)
  p1:set(bbCenter) p1:setAdd(bbAxis0) p1:setAdd(bbAxis1) p1:setSub(bbAxis2)
  p2:set(bbCenter) p2:setAdd(bbAxis0) p2:setAdd(bbAxis1) p2:setAdd(bbAxis2)
  p3:set(bbCenter) p3:setSub(bbAxis0) p3:setAdd(bbAxis1) p3:setAdd(bbAxis2)
  p4:set(bbCenter) p4:setSub(bbAxis0) p4:setAdd(bbAxis1) p4:setSub(bbAxis2)
  p5:set(bbCenter) p5:setAdd(bbAxis0) p5:setSub(bbAxis1) p5:setSub(bbAxis2)
  p6:set(bbCenter) p6:setAdd(bbAxis0) p6:setSub(bbAxis1) p6:setAdd(bbAxis2)
  p7:set(bbCenter) p7:setSub(bbAxis0) p7:setSub(bbAxis1) p7:setAdd(bbAxis2)
  p8:set(bbCenter) p8:setSub(bbAxis0) p8:setSub(bbAxis1) p8:setSub(bbAxis2)
  bbPoints[1] = p1; bbPoints[2] = p2; bbPoints[3] = p3; bbPoints[4] = p4;
  bbPoints[5] = p5; bbPoints[6] = p6; bbPoints[7] = p7; bbPoints[8] = p8;
  return bbPoints
end

local veh

local updateData = {}
local decals = {}
local nearbyIds = {}
local quadTreeSettings = {}
local clustersById = {}
local interactableElements = {}

local lastCamPos = vec3()
local lastCamVel = vec3()
local playerVelLast = vec3()
local timeSincePlayerTeleport

local markerVisibilityBySetting = {}

-- Player footprint comes from overhaul_playerVehicles: coupler group plus
-- nearby spawned inventory vehicles so an uncoupled trailer in a stall still
-- opens the parking prompt.
local playerVehIds = {}
local bbPointsScratch = {}
local playerBBSnap = {
  center = vec3(),
  axis0 = vec3(),
  axis1 = vec3(),
  axis2 = vec3(),
  points = {},
  playerPos = vec3()
}
local probePos = vec3()
local posSnapScratch = vec3()
local lastSecondaryHitId = nil

-- Seated vehicle keeps the normal 100 m nearby query.
-- Extra player vehicles pull markers in a local bubble large enough for a
-- long tanker whose OOB center sits well behind the parking stall.
local SECONDARY_NEAR_RADIUS = 50
local SECONDARY_NEAR_RADIUS_SQ = SECONDARY_NEAR_RADIUS * SECONDARY_NEAR_RADIUS

local function syncPlayerVehicles(seatedVehId)
  table.clear(playerVehIds)
  if overhaul_playerVehicles and overhaul_playerVehicles.fillInteractionVehicleIds then
    overhaul_playerVehicles.fillInteractionVehicleIds(playerVehIds)
  elseif overhaul_playerVehicles and overhaul_playerVehicles.fillPlayerVehicleIds then
    overhaul_playerVehicles.fillPlayerVehicleIds(playerVehIds)
  elseif seatedVehId then
    playerVehIds[1] = seatedVehId
  end
end

local function copyBBPointsInto(dst, src)
  for i, p in ipairs(src or {}) do
    if dst[i] then
      dst[i]:set(p)
    else
      dst[i] = vec3(p)
    end
  end
  for i = #(src or {}) + 1, #dst do
    dst[i] = nil
  end
  return dst
end

local function takePlayerBBSnap()
  if not updateData.bbCenter then return nil end
  playerBBSnap.center:set(updateData.bbCenter)
  playerBBSnap.axis0:set(updateData.bbHalfAxis0)
  playerBBSnap.axis1:set(updateData.bbHalfAxis1)
  playerBBSnap.axis2:set(updateData.bbHalfAxis2)
  copyBBPointsInto(playerBBSnap.points, updateData.bbPoints)
  playerBBSnap.topZ = updateData.highestBBPointZ
  playerBBSnap.playerPos:set(updateData.playerPosition)
  return playerBBSnap
end

local function applyVehBB(vehId)
  updateData.bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  updateData.bbHalfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  updateData.bbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  updateData.bbHalfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
  updateData.bbPoints = getBBPoints(updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)
  updateData.highestBBPointZ = math.max(updateData.bbPoints[2].z, math.max(updateData.bbPoints[3].z, math.max(updateData.bbPoints[6].z, updateData.bbPoints[7].z)))
  updateData.playerPosition:set(updateData.bbCenter)
end

local function restorePlayerBBSnap(snap)
  if not snap then return end
  updateData.bbCenter:set(snap.center)
  updateData.bbHalfAxis0:set(snap.axis0)
  updateData.bbHalfAxis1:set(snap.axis1)
  updateData.bbHalfAxis2:set(snap.axis2)
  updateData.bbPoints = copyBBPointsInto(bbPointsScratch, snap.points)
  updateData.highestBBPointZ = snap.topZ
  updateData.playerPosition:set(snap.playerPos)
end

local function markerOverlaps(marker)
  return marker.overlap ~= false and marker.overlap ~= nil
end

-- Probe overlap without ticking marker smoothers (marker:update applies dt each call).
-- Vanilla checkParking also refuses anything whose *center* is farther than 15 m,
-- which a long trailer can fail while its bounding box still covers the stall.
local function probeMarkerOverlap(marker)
  if marker.pos and marker.xVec and marker.yVec and marker.zVec and updateData.bbCenter
      and updateData.bbHalfAxis0 and updateData.bbHalfAxis1 and updateData.bbHalfAxis2 then
    local hit
    if marker.mode == "contained" then
      hit = containsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec,
        updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)
    else
      hit = overlapsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec,
        updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)
    end
    if hit then
      marker.overlap = true
      if marker.parked ~= nil then marker.parked = true end
      return true
    end
  end
  if marker.checkParking then
    marker:checkParking(updateData)
  else
    marker:update(updateData)
  end
  return markerOverlaps(marker)
end

-- Default = stock marker:update with seated BB.
-- Extra player bodies (coupled or nearby inventory) are probed against every
-- nearby marker; cheap-reject only skips bodies whose center is far away.
local function updateMarkerForPlayerVehicles(marker, clusterPos)
  lastSecondaryHitId = nil
  if #playerVehIds < 2 then
    marker:update(updateData)
    return false
  end

  local markerPos = clusterPos or marker.pos
  local snap = takePlayerBBSnap()
  local hitId = nil

  for i = 2, #playerVehIds do
    local vehId = playerVehIds[i]
    local tooFar = false
    if markerPos then
      probePos:set(be:getObjectOOBBCenterXYZ(vehId))
      local dx = probePos.x - markerPos.x
      local dy = probePos.y - markerPos.y
      local dz = probePos.z - markerPos.z
      tooFar = (dx * dx + dy * dy + dz * dz) > SECONDARY_NEAR_RADIUS_SQ
    end
    if not tooFar then
      applyVehBB(vehId)
      if probeMarkerOverlap(marker) then
        hitId = vehId
        break
      end
    end
  end

  restorePlayerBBSnap(snap)
  -- Seated update drives icons/smoothers, but must not erase a secondary park hit.
  marker:update(updateData)
  if hitId then
    if marker.parked ~= nil then marker.parked = true end
    if marker.overlap ~= nil then marker.overlap = true end
  end
  lastSecondaryHitId = hitId
  return hitId ~= nil
end

local function interactablePromptKey(elements)
  local keys = {}
  for i, elem in ipairs(elements or {}) do
    keys[i] = string.format("%s|%s|%s|%s|%s|%s",
      elem.type or "", elem.psPath or "", elem.missionId or "",
      elem.facId or "", tostring(elem.canInspectCargo), tostring(elem.hasPlayerCargo))
  end
  table.sort(keys)
  return table.concat(keys, ";;")
end

local function collectMarkerInteractables(marker, secondaryHit, snap, isAtParkingSpeed, isWalking, parkingSpeedChanged)
  local canInteract = isAtParkingSpeed and (forceReevaluateOpenPrompt or parkingSpeedChanged)
  if isWalking then
    canInteract = marker.isInAreaChanged or forceReevaluateOpenPrompt or secondaryHit
  elseif secondaryHit and isAtParkingSpeed then
    canInteract = true
  end

  updateData.canInteract = canInteract
  if not canInteract then return end

  local countBefore = #interactableElements
  marker:interactInPlayMode(updateData, interactableElements)
  if not secondaryHit or #interactableElements > countBefore or not snap or not lastSecondaryHitId then return end

  if marker.parked ~= nil then marker.parked = true end
  if marker.overlap ~= nil then marker.overlap = true end

  posSnapScratch:set(updateData.playerPosition)
  applyVehBB(lastSecondaryHitId)
  marker:interactInPlayMode(updateData, interactableElements)
  restorePlayerBBSnap(snap)
  updateData.playerPosition:set(posSnapScratch)
end

-- Unbuilt / cleared KD trees have nil tree/nonLeafLimIdx; querying them exceptions every frame.
local function isQueryableClusterQt(clusterQt)
  return clusterQt and clusterQt.tree and clusterQt.nonLeafLimIdx
end

-- Only secondary player vehicles expand the nearby set, and only in a tight radius.
local function queryClustersNearSecondaryPlayerVehicles(clusterQt, outIds)
  if not isQueryableClusterQt(clusterQt) then
    return
  end
  for i = 2, #playerVehIds do
    probePos:set(be:getObjectOOBBCenterXYZ(playerVehIds[i]))
    for id in clusterQt:queryNotNested(
      probePos.x - SECONDARY_NEAR_RADIUS,
      probePos.y - SECONDARY_NEAR_RADIUS,
      probePos.x + SECONDARY_NEAR_RADIUS,
      probePos.y + SECONDARY_NEAR_RADIUS
    ) do
      outIds[id] = true
    end
  end
end

local function displayMissionMarkers(level, dtSim, dtReal)
  profilerPushEvent("MissionMarker precalc")
  local activeMission = gameplay_missions_missionManager.getForegroundMissionId()
  local globalAlpha = 1
  if activeMission then
    globalAlpha = 0
  end
  veh = getPlayerVehicle(0)

  if veh then
    updateData.veh = veh
    updateData.vehPos = updateData.vehPos or vec3()
    updateData.vehPos:set(veh:getPositionXYZ())
    updateData.vehPos2d = updateData.vehPos2d or vec3()
    updateData.vehPos2d:set(updateData.vehPos)
    updateData.vehPos2d.z = 0
    updateData.vehVelocity = updateData.vehVelocity or vec3()
    updateData.vehVelocity:set(veh:getVelocityXYZ())

    local vehId = veh:getID()
    updateData.bbCenter = updateData.bbCenter or vec3()
    updateData.bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
    updateData.bbHalfAxis0 = updateData.bbHalfAxis0 or vec3()
    updateData.bbHalfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
    updateData.bbHalfAxis1 = updateData.bbHalfAxis1 or vec3()
    updateData.bbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
    updateData.bbHalfAxis2 = updateData.bbHalfAxis2 or vec3()
    updateData.bbHalfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))

    updateData.bbPoints = getBBPoints(updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)

    updateData.highestBBPointZ = math.max(updateData.bbPoints[2].z, math.max(updateData.bbPoints[3].z, math.max(updateData.bbPoints[6].z, updateData.bbPoints[7].z)))
    syncPlayerVehicles(vehId)
  else
    updateData.veh = nil
    table.clear(playerVehIds)
  end

  updateData.camPos = updateData.camPos or vec3()
  updateData.camPos:set(core_camera.getPositionXYZ())
  -- Dedicated vector: applyVehBB writes playerPosition in place and must not mutate vehPos/camPos.
  updateData.playerPosition = updateData.playerPosition or vec3()
  if veh then
    updateData.playerPosition:set(updateData.vehPos)
  else
    updateData.playerPosition:set(updateData.camPos)
  end

  local playerVelocity = getVelocity(dtSim, updateData.playerPosition)
  -- this is 64 garbage
  updateData.isWalking = gameplay_walk and gameplay_walk.isWalking() or false

  profilerPushEvent("MissionEnter parkingSpeedFactor")
  local parkingSpeedFactor, isAtParkingSpeed, parkingSpeedChanged = getParkingSpeedFactor(playerVelocity)
  local cruisingSpeedFactor, isAtcruisingSpeed, cruisingSpeedChanged = getCruisingSpeedFactor(playerVelocity)


  profilerPopEvent("MissionEnter parkingSpeedFactor")
  -- put reference for icon manager in
  updateData.parkingSpeedFactor = parkingSpeedFactor
  updateData.cruisingSpeedFactor = cruisingSpeedFactor
  updateData.dt = dtReal
  updateData.globalAlpha = globalAlpha
  updateData.camRot = updateData.camRot or quat()
  updateData.camRot:set(core_camera.getQuatXYZW())
  updateData.bigMapActive = freeroam_bigMapMode.bigMapActive()
  updateData.bigmapTransitionActive = freeroam_bigMapMode.isTransitionActive()
  updateData.isFreeCam = commands.isFreeCamera()
  updateData.windowAspectRatio = screenRatio
  updateData.screenHeight = screenHeight
  -- TODO: Clean this up
  table.clear(nearbyIds)
  -- hide all the markers behind the camera
  local maxRadius = 100
  profilerPushEvent("MissionEnter QTStuff")
      -- transitioning or normal play mode
  if   (not freeroam_bigMapMode.bigMapActive())
    or (freeroam_bigMapMode.bigMapActive() and freeroam_bigMapMode.isTransitionActive()) then
    local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
    if isQueryableClusterQt(clusterQt) and updateData.playerPosition then
      -- Stock nearby set around the seated vehicle / player position.
      for id in clusterQt:queryNotNested(updateData.playerPosition.x-maxRadius, updateData.playerPosition.y-maxRadius, updateData.playerPosition.x+maxRadius, updateData.playerPosition.y + maxRadius) do
        nearbyIds[id] = true
      end
      -- Coupled extras only add markers in their small local bubble.
      if #playerVehIds > 1 then
        queryClustersNearSecondaryPlayerVehicles(clusterQt, nearbyIds)
      end

      if updateData.isFreeCam and updateData.camPos then
        for id in clusterQt:queryNotNested(updateData.camPos.x-maxRadius, updateData.camPos.y-maxRadius, updateData.camPos.x+maxRadius, updateData.camPos.y + maxRadius) do
          nearbyIds[id] = true
        end
      end
    end
  end

  if M.navigationPoiId  then
    nearbyIds[M.navigationPoiId] = true
  end

  profilerPopEvent("MissionEnter QTStuff")
  --table.clear(visibleIdsSorted)
  --tableKeys(visibleIds, visibleIdsSorted)
  --table.sort(visibleIdsSorted)
  profilerPopEvent("MissionEnter precalc")

  -- now cleared at the end
  --if not isAtParkingSpeed then
    --table.clear(currentInteractableElements)
  --end

  table.clear(decals)

  local decalCount = 0
  local careerActive = (career_career and career_career.isActive())
  local tutorialActive = gameplay_discover_freeroamTutorial_tutorial ~= nil
  table.clear(interactableElements)
  local showMissionMarkers = markersVisibleTemporary
  markerVisibilityBySetting.showMissionMarkers = (careerActive or tutorialActive or settings.getValue("showMissionMarkers"))
  --markerVisibilityBySetting.enableDragRaceInFreeroam = (careerActive or settings.getValue("enableDragRaceInFreeroam"))
  --markerVisibilityBySetting.enableDriftInFreeroam = (careerActive or settings.getValue("enableDriftInFreeroam"))
  --markerVisibilityBySetting.enableGasStationsInFreeroam = (careerActive or settings.getValue("enableGasStationsInFreeroam"))
  -- draw/show all visible markers.
  --[[
  if not timeSincePlayerTeleport then
    timeSincePlayerTeleport = objectTeleported(updateData.camPos, lastCamPos, playerVelLast, dtReal) and 0.5
  end
  if timeSincePlayerTeleport then
    timeSincePlayerTeleport = timeSincePlayerTeleport - dtReal
    if timeSincePlayerTeleport <= 0 then timeSincePlayerTeleport = nil end
  end]]
  --local testId = "parkingMarker#/levels/west_coast_usa/facilities/delivery/mechanics.sites.json#exhaustShop_parking"
  local anyMarkerIsInAreaChanged = false
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
    if nearbyIds[cluster.id] or marker.focus then
      -- Check if the marker should be visible
      cluster.focus = cluster.focus or cluster.id == M.navigationPoiId
      local showMarker = not photoModeOpen
      and not (editor and editor.active)
      and (showMissionMarkers or cluster.focus)
      showMarker = showMarker and (not cluster.visibleBySetting or markerVisibilityBySetting[cluster.visibleBySetting] or cluster.focus)
      --dump(string.format("cluster %s, is nearby: %s, marker focus: %s, cluster focus: %s", cluster.id, nearbyIds[cluster.id], marker.focus, cluster.focus))
      --dump(string.format("cluster %s, is showMarker: %s", cluster.id, showMarker))
      --simpleDebugText3d(string.format("marker %s, is showMarker: %s", cluster.id, showMarker), cluster.pos)
      if showMarker then
        -- debug drawing for testing
        --debugDrawer:drawTextAdvanced(marker.pos, String(tostring(cluster.id)), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
        --debugDrawer:drawSphere(cluster.pos, cluster.radius, ColorF(0.91,0.05,0.48,0.2))
        marker:show()
        local secondaryHit = updateMarkerForPlayerVehicles(marker, cluster.pos)
        local playerSnap = secondaryHit and takePlayerBBSnap() or nil
        -- post-marker decals, so they can be all drawn at once

        -- TODO: optimize
        if marker.groundDecalData then
          if marker.groundDecalData.texture then
            decalCount = decalCount + 1
            decals[decalCount] = marker.groundDecalData
          else
            for _, decal in ipairs(marker.groundDecalData) do
              decalCount = decalCount + 1
              decals[decalCount] = decal
            end
          end
        end

        if veh then
          if not freeroam_bigMapMode.bigMapActive() and not activeMission and not
            (gameplay_drift_freeroam_driftSpots and gameplay_drift_freeroam_driftSpots.getIsInFreeroamChallenge()) then
            if marker.interactInPlayMode then
            -- todo: optimize this
              if updateData.isWalking and marker.isInAreaChanged then
                anyMarkerIsInAreaChanged = marker.isInAreaChanged
              end
              collectMarkerInteractables(marker, secondaryHit, playerSnap, isAtParkingSpeed, updateData.isWalking, parkingSpeedChanged)
              --simpleDebugText3d(dumps(marker.cluster.clusterId), marker.cluster.pos, 0.25)
            end
            if marker.interactWhileMoving then
              marker:interactWhileMoving(updateData)
            end
          end
        end
      else
        marker:hide()
      end
    else
      marker:hide()
    end
  end
  lastCamPos:set(updateData.camPos)
  if veh then
    playerVelLast:set(be:getObjectVelocityXYZ(veh:getID()))
  end
  --print("Force forceReevaluateOpenPrompt " .. dumps(forceReevaluateOpenPrompt))
  local shouldRefreshPrompt = forceReevaluateOpenPrompt
  forceReevaluateOpenPrompt = false
  if next(interactableElements) then
    local promptKey = interactablePromptKey(interactableElements)
    if promptKey ~= cachedInteractablePromptKey or shouldRefreshPrompt then
      local alreadyShowingSame = cachedInteractablePromptKey == promptKey
      local alreadySettlingSame = pendingPromptElements and pendingPromptKey == promptKey
      -- Do not restart the settle timer every frame while cachedInteractablePromptKey
      -- is still nil. Let the existing pending prompt count down and open.
      if not alreadySettlingSame or shouldRefreshPrompt then
        -- Walking has no parking-brake beat; refresh of an already-open prompt should be instant.
        if updateData.isWalking or (shouldRefreshPrompt and alreadyShowingSame) then
          clearPendingPrompt()
          openPromptFromElements(interactableElements, promptKey)
        else
          pendingPromptElements = {}
          for i, elem in ipairs(interactableElements) do
            pendingPromptElements[i] = elem
          end
          pendingPromptKey = promptKey
          promptSettleTimer = PROMPT_SETTLE_DELAY
        end
      end
    end
  end

  if promptSettleTimer then
    if not isAtParkingSpeed then
      clearPendingPrompt()
    else
      promptSettleTimer = promptSettleTimer - dtReal
      if promptSettleTimer <= 0 and pendingPromptElements then
        openPromptFromElements(pendingPromptElements, pendingPromptKey)
        clearPendingPrompt()
      end
    end
  end

  if not activeMission and not next(interactableElements) then
    if updateData.isWalking then
      if anyMarkerIsInAreaChanged == "out" then
        table.clear(currentInteractableElements)
        cachedInteractablePromptKey = nil
        clearPendingPrompt()
        closeViewDetailPrompt(true)
      end
    elseif not isAtParkingSpeed or parkingSpeedChanged then
      table.clear(currentInteractableElements)
      cachedInteractablePromptKey = nil
      clearPendingPrompt()
      closeViewDetailPrompt(parkingSpeedChanged)
    end
  end
  skipIconFading = false
  Engine.Render.DynamicDecalMgr.addDecals(decals, decalCount)
end

local pos2Offset = vec3(0, 0, 1000)
local columnColor = ColorF(1,1,1,1)
local missingPlaymodeStateFrames = 0
local PLAYMODE_CLEAR_GRACE_FRAMES = 5

local function asNavVec3(value)
  if value == nil then return nil end
  local valueType = type(value)
  if valueType == "cdata" then return value end
  if valueType == "table" then
    if value.x and value.y and value.z then
      return vec3(value.x, value.y, value.z)
    end
    if value[1] and value[2] and value[3] then
      return vec3(value[1], value[2], value[3])
    end
  end
  return nil
end

local function getActiveRoutePath()
  local planner = core_groundMarkers and core_groundMarkers.routePlanner
  local path = planner and planner.path
  if path and path[1] and path[1].pos then
    return path
  end
  return nil
end

local function getNavColumnPos()
  local planner = core_groundMarkers and core_groundMarkers.routePlanner
  if planner and planner.getNextFixedWP then
    local nextFixed = asNavVec3(planner:getNextFixedWP())
    if nextFixed then return nextFixed end
  end
  if core_groundMarkers.getTargetPos then
    local target = asNavVec3(core_groundMarkers.getTargetPos())
    if target then return target end
  end
  local endWP = core_groundMarkers and core_groundMarkers.endWP
  if type(endWP) == "table" then
    return asNavVec3(endWP[#endWP] or endWP[1])
  end
  return asNavVec3(endWP)
end

local function drawDistanceColumn(targetPos)
  local camPos = core_camera.getPosition()
  local dist = camPos:distance(targetPos)
  local radius = math.max(dist/400, 0.1)
  local targetPos2 = targetPos + pos2Offset
  local alpha = clamp((dist-50)/200, 0.1, 0.6)
  columnColor.alpha = alpha
  debugDrawer:drawCylinder(targetPos, targetPos2, radius, columnColor)
end

local function resetForceVisible()
  -- Set all markers forceVisible to false
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    if string.startswith(cluster.id, "missionMarker") then
      cluster.focus = false
    end
  end

  M.reachedTargetPos = nil
  M.navigationPoiId = nil
end

local function reachedTarget()
  if not core_groundMarkers.clearPathOnReachingTarget then return end
  if settings.getValue("showMissionMarkers") or (career_career and career_career.isActive()) then
    resetForceVisible()
  end
  M.reachedTargetPos = core_groundMarkers.endWP[1]
  extensions.hook("onReachedTargetPos")
  ui_message("bigmap.info.reachedTarget", nil, "bigmapTarget", "checkmark")
end


local function onPreRender(dtReal, dtSim)
  local playmodeOk = gameplay_playmodeMarkers.isStateWithPlaymodeMarkers()
  if playmodeOk then
    missingPlaymodeStateFrames = 0
  else
    missingPlaymodeStateFrames = missingPlaymodeStateFrames + 1
    if missingPlaymodeStateFrames >= PLAYMODE_CLEAR_GRACE_FRAMES then
      gameplay_playmodeMarkers.clear()
    end
  end

  profilerPushEvent("MissionEnter onPreRender")
  profilerPushEvent("MissionEnter groundMarkers")
  -- Keep the destination column up whenever a route exists. Stock only draws it
  -- when clearPathOnReachingTarget is set, and treats an empty planner (length 0)
  -- as arrival, which wipes nav after a map/UI hitch.
  if gameplay_missions_missionManager then
    if gameplay_missions_missionManager.getForegroundMissionId() == nil
      and core_groundMarkers and core_groundMarkers.currentlyHasTarget
      and core_groundMarkers.currentlyHasTarget()
      and freeroam_bigMapMode and not freeroam_bigMapMode.bigMapActive() then
      local columnPos = getNavColumnPos()
      if columnPos then
        drawDistanceColumn(columnPos)
      end
      local path = getActiveRoutePath()
      local remaining = path and path[1] and path[1].distToTarget
      if core_groundMarkers.clearPathOnReachingTarget and remaining ~= nil and remaining < 7 then
        reachedTarget()
      end
    end
    if M.reachedTargetPos then
      local veh = getPlayerVehicle(0)
      if veh then
        local vehPos = veh:getPosition()
        if vehPos:distance(M.reachedTargetPos) > 20 then
          resetForceVisible()
        end
      end
    end
  end

  profilerPopEvent("MissionEnter groundMarkers")

  if playmodeOk then
    local level = getCurrentLevelIdentifier()
    if level then
      profilerPushEvent("DisplayMissionMarkers")
      displayMissionMarkers(level, dtSim, dtReal)
      profilerPopEvent("DisplayMissionMarkers")
    end
  end

  profilerPopEvent("MissionEnter onPreRender")

end


local function clearCache()
  M.setForceReevaluateOpenPrompt()
end


local function skipNextIconFading()
  skipIconFading = true
end

local function showMissionMarkersToggled(active)
  gameplay_rawPois.clear()
  freeroam_bigMapPoiProvider.forceSend()
end


local function onAnyMissionChanged(state)
  freeroam_bigMapPoiProvider.forceSend()
  if state == "started" then
    freeroam_bigMapMode.deselect()
    resetForceVisible()
  end
end

local function onNavigateToMission(poiId)
  resetForceVisible()
  M.navigationPoiId = poiId
end



local function onClientEndMission(levelPath)
  M.navigationPoiId = nil
  clearPendingPrompt()
  unlockActivityPromptInput()
end

local function onExtensionUnloaded()
  unlockActivityPromptInput()
end
M.onExtensionUnloaded = onExtensionUnloaded

local function setMarkersVisibleTemporary(visible)
  markersVisibleTemporary = visible
end

M.closeViewDetailPrompt = closeViewDetailPrompt
M.showMissionMarkersToggled = showMissionMarkersToggled
M.setMarkersVisibleTemporary = setMarkersVisibleTemporary

M.restartCurrent = restartCurrent
M.abandonCurrent = abandonCurrent

M.skipNextIconFading = skipNextIconFading
M.onPreRender = onPreRender

M.getClusterMarker = getClusterMarker

M.onNavigateToMission = onNavigateToMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onClientEndMission = onClientEndMission
M.clearCache = clearCache
M.setForceReevaluateOpenPrompt = function()
  forceReevaluateOpenPrompt = true
end

M.onUIPlayStateChanged = function(enteredPlay)
  if enteredPlay then
    M.setForceReevaluateOpenPrompt()
  end
end
-- Extension reloads can reuse the previous export table. Explicitly clear the
-- removed global destination-marker API so hot reload matches a fresh launch.
M.onSetBigmapNavFocus = nil
M.getNavigationDestinationMarkerState = nil
M.setNavigationDestinationTarget = nil
M.clearNavigationDestinationTarget = nil
return M
