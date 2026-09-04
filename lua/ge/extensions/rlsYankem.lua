-- Project Yankem: universal vehicle-to-vehicle winch controller.

local M = {}

local logTag = "rlsYankem"

local STATE_IDLE = "idle"
local STATE_SELECTING_FIRST = "selectingFirst"
local STATE_SELECTING_SECOND = "selectingSecond"
local STATE_CONNECTED = "connected"

local selectionRange = 30
local maxCableLength = 30
local minCableLength = 0.25
local forestAnchorHeight = 1.5
local forestMinimumHeight = 2.0
local spoolSpeed = 0.447
local tautEpsilon = 0.005
local maxTension = 1000000
local controllerFrequencyHz = 2
local controllerAngularFrequency = 2 * math.pi * controllerFrequencyHz
local dampingRatio = 0.75
local minSpringStiffness = 400000
local maxSpringStiffness = 1200000
-- Reel-in starts at the base ceiling and ramps to the original high ceiling
-- only while stalled. This retains locked-equipment authority without using
-- the full ceiling as an impulse on a freely moving endpoint.
local linearAccelCap = 250
local baseLinearAccelCap = 15
local pullAuthorityRampRate = 40
local pullAuthorityReleaseRate = 120
local stallClosingSpeed = spoolSpeed * 0.25
local constraintAccelCap = 20
local constraintReleaseSlack = 0.1
local angularAccelCap = 8
local holdAngularAccelCap = 2

local pointOrder = {
  "frontLeft", "frontCenter", "frontRight",
  "rearLeft", "rearCenter", "rearRight",
  "leftCenter", "rightCenter"
}

local pointLabels = {
  frontLeft = "Front left",
  frontCenter = "Front center",
  frontRight = "Front right",
  rearLeft = "Rear left",
  rearCenter = "Rear center",
  rearRight = "Rear right",
  leftCenter = "Left side",
  rightCenter = "Right side"
}


local markerColor = ColorF(0.18, 0.62, 1.0, 0.9)
local markerHoverColor = ColorF(1.0, 0.86, 0.18, 1.0)
local markerSelectedColor = ColorF(0.1, 1.0, 0.9, 1.0)
local cableSlackColor = ColorF(0.55, 0.58, 0.62, 1.0)
local cableTensionColor = ColorF(1.0, 0.42, 0.08, 1.0)
local cableReelingColor = ColorF(0.18, 1.0, 0.35, 1.0)

local state = STATE_IDLE
local endpointA
local endpointB
local targetLength = 0
local currentLength = 0
local currentTension = 0
local reelDirection = 0
local isTaut = false
local lastLength
local currentStretch = 0
local currentSeparationRate = 0
local currentEffectiveMass = 0
local currentSpringStiffness = 0
local currentDamping = 0
local currentControllerForce = 0
local currentLinearAccelCap = baseLinearAccelCap
local constraintEngaged = false
local forceWasApplied = false
local disconnectReason
local boxCache = {}
local visibleMarkers = {}
local hoveredMarker
local endpointProperties = {}
local connectionSerial = 0
local uiTimer = 0

local function clampValue(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function vecToTable(v)
  return {v.x, v.y, v.z}
end

local function vehicleName(veh)
  if not veh then return "Unknown" end
  local ok, name = pcall(function() return veh:getJBeamFilename() end)
  return ok and name or ("Vehicle " .. tostring(veh:getID()))
end

local function getVehicle(vehicleId)
  if not vehicleId then return nil end
  local veh = getObjectByID(vehicleId)
  if not veh or not veh.getNodeCount or veh:getNodeCount() <= 0 then return nil end
  return veh
end

local function notifyUi()
  if not guihooks then return end
  guihooks.trigger("RlsYankemState", M.getUiState())
end

local function shortMessage(message, icon)
  if ui_message then ui_message(message, 2, "rlsYankem", icon or "info") end
end

local function collectInitialClusterBounds(veh, refNodeId, collidableOnly)
  local clusters = veh:getNodeClusters()
  local targetCluster = clusters and clusters[refNodeId + 1]
  if targetCluster == nil then return nil end

  local minX, minY, minZ = math.huge, math.huge, math.huge
  local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
  local count = 0

  for nodeId = 0, veh:getNodeCount() - 1 do
    if clusters[nodeId + 1] == targetCluster then
      local include = true
      if collidableOnly then
        local ok, collisionType = pcall(function() return veh:getInitialNodeCollision(nodeId) end)
        include = ok and collisionType == 3
      end
      if include then
        local p = veh:getInitialNodePosition(nodeId)
        if p then
          minX, minY, minZ = math.min(minX, p.x), math.min(minY, p.y), math.min(minZ, p.z)
          maxX, maxY, maxZ = math.max(maxX, p.x), math.max(maxY, p.y), math.max(maxZ, p.z)
          count = count + 1
        end
      end
    end
  end

  if count == 0 then return nil end
  return {
    min = vec3(minX, minY, minZ),
    max = vec3(maxX, maxY, maxZ),
    count = count
  }
end

local function findClosestClusterNode(veh, refNodeId, target, extents, collidableOnly)
  local clusters = veh:getNodeClusters()
  local targetCluster = clusters and clusters[refNodeId + 1]
  if targetCluster == nil then return nil end

  local scaleX = math.max(extents.x, 0.1)
  local scaleY = math.max(extents.y, 0.1)
  local scaleZ = math.max(extents.z, 0.1)
  local bestNodeId
  local bestDistance = math.huge

  for nodeId = 0, veh:getNodeCount() - 1 do
    if clusters[nodeId + 1] == targetCluster then
      local include = true
      if collidableOnly then
        local ok, collisionType = pcall(function() return veh:getInitialNodeCollision(nodeId) end)
        include = ok and collisionType == 3
      end
      if include then
        local p = veh:getInitialNodePosition(nodeId)
        if p then
          local dx = (p.x - target.x) / scaleX
          local dy = (p.y - target.y) / scaleY
          local dz = (p.z - target.z) / scaleZ
          -- Longitudinal/lateral placement matters more than matching the
          -- virtual box height; otherwise low deck nodes can win several
          -- metres away from an end or corner.
          local distance = dx * dx + dy * dy + dz * dz * 0.25
          if distance < bestDistance then
            bestDistance = distance
            bestNodeId = nodeId
          end
        end
      end
    end
  end

  return bestNodeId
end

local function buildVehicleBox(veh)
  if not veh or veh:getNodeCount() <= 0 then return nil end
  local refNodeId = veh:getRefNodeId()
  if refNodeId == nil or refNodeId < 0 then return nil end

  local bounds = collectInitialClusterBounds(veh, refNodeId, true)
    or collectInitialClusterBounds(veh, refNodeId, false)
  if not bounds then return nil end

  local extents = bounds.max - bounds.min
  if extents.x < 0.05 or extents.y < 0.05 or extents.z < 0.05 then return nil end

  local refInitial = veh:getInitialNodePosition(refNodeId)
  if not refInitial then return nil end

  local centerX = (bounds.min.x + bounds.max.x) * 0.5
  local centerY = (bounds.min.y + bounds.max.y) * 0.5
  local centerZ = bounds.min.z + extents.z * 0.275
  local lateral = extents.x * 0.5 * 0.7

  local function relativePoint(x, y, z)
    return vec3(x, y, z or centerZ) - refInitial
  end

  local absolutePoints = {
    frontLeft = vec3(centerX - lateral, bounds.max.y, centerZ),
    frontCenter = vec3(centerX, bounds.max.y, centerZ),
    frontRight = vec3(centerX + lateral, bounds.max.y, centerZ),
    rearLeft = vec3(centerX - lateral, bounds.min.y, centerZ),
    rearCenter = vec3(centerX, bounds.min.y, centerZ),
    rearRight = vec3(centerX + lateral, bounds.min.y, centerZ),
    leftCenter = vec3(bounds.min.x, centerY, centerZ),
    rightCenter = vec3(bounds.max.x, centerY, centerZ)
  }

  local points = {
    frontLeft = relativePoint(centerX - lateral, bounds.max.y),
    frontCenter = relativePoint(centerX, bounds.max.y),
    frontRight = relativePoint(centerX + lateral, bounds.max.y),
    rearLeft = relativePoint(centerX - lateral, bounds.min.y),
    rearCenter = relativePoint(centerX, bounds.min.y),
    rearRight = relativePoint(centerX + lateral, bounds.min.y),
    leftCenter = relativePoint(bounds.min.x, centerY),
    rightCenter = relativePoint(bounds.max.x, centerY)
  }


  local pointNodeIds = {}
  for pointKey, target in pairs(absolutePoints) do
    pointNodeIds[pointKey] = findClosestClusterNode(veh, refNodeId, target, extents, true)
      or findClosestClusterNode(veh, refNodeId, target, extents, false)
  end

  return {
    vehicleId = veh:getID(),
    refNodeId = refNodeId,
    nodeCount = veh:getNodeCount(),
    model = vehicleName(veh),
    points = points,
    pointNodeIds = pointNodeIds,
    bounds = {min = vecToTable(bounds.min), max = vecToTable(bounds.max)}
  }
end

local function getVehicleBox(veh)
  if not veh then return nil end
  local vehicleId = veh:getID()
  local cached = boxCache[vehicleId]
  if cached and cached.nodeCount == veh:getNodeCount() and cached.refNodeId == veh:getRefNodeId() then
    return cached
  end
  cached = buildVehicleBox(veh)
  boxCache[vehicleId] = cached
  return cached
end

local function pointWorldPosition(veh, box, pointKey)
  local localPoint = box and box.points[pointKey]
  if not veh or not localPoint then return nil end

  -- Bind each virtual box point to the closest real node. Besides keeping the
  -- point on the vehicle surface, this follows articulated/deformed bodies such
  -- as tilt decks. getClusterRotationSlow expects a cluster id; passing the ref
  -- node id here produced unrelated rotations on some multi-body vehicles.
  local nodeId = box.pointNodeIds and box.pointNodeIds[pointKey]
  if nodeId ~= nil then
    local ok, nodePosition = pcall(function() return veh:getNodePosition(nodeId) end)
    if ok and nodePosition then return veh:getPosition() + nodePosition end
  end

  -- Rigid fallback using BeamNG's vehicle basis. Vehicle local +Y points rearward.
  local rawForward = veh:getDirectionVector()
  local rawUp = veh:getDirectionVectorUp()
  if not rawForward or not rawUp then return nil end
  local forward = vec3(rawForward.x, rawForward.y, rawForward.z)
  local up = vec3(rawUp.x, rawUp.y, rawUp.z)
  if forward:squaredLength() < 1e-8 or up:squaredLength() < 1e-8 then return nil end
  forward:normalize()
  up:normalize()
  local localX = up:cross(forward)
  if localX:squaredLength() < 1e-8 then return nil end
  localX:normalize()
  return veh:getPosition() + localX * localPoint.x - forward * localPoint.y + up * localPoint.z
end

local function endpointWorldPosition(endpoint)
  if not endpoint then return nil end
  if endpoint.kind == "static" then return endpoint.worldPosition end
  local veh = getVehicle(endpoint.vehicleId)
  if not veh then return nil end
  local box = getVehicleBox(veh)
  if not box or box.refNodeId ~= endpoint.refNodeId then return nil end
  return pointWorldPosition(veh, box, endpoint.pointKey), veh, box
end

local function makeEndpoint(veh, box, pointKey)
  return {
    kind = "vehicle",
    vehicleId = veh:getID(),
    vehicleName = vehicleName(veh),
    refNodeId = box.refNodeId,
    pointKey = pointKey,
    pointLabel = pointLabels[pointKey] or pointKey
  }
end

local function makeStaticEndpoint(marker)
  return {
    kind = "static",
    vehicleName = marker.vehicleName,
    pointKey = marker.pointKey,
    pointLabel = marker.pointLabel,
    staticId = marker.staticId,
    worldPosition = vec3(marker.worldPos.x, marker.worldPos.y, marker.worldPos.z)
  }
end

local function makeEndpointFromMarker(marker)
  if marker.kind == "static" then return makeStaticEndpoint(marker) end
  return makeEndpoint(marker.vehicle, marker.box, marker.pointKey)
end

local function raySphereDistance(rayOrigin, rayDirection, center, radius)
  local toCenter = center - rayOrigin
  local along = toCenter:dot(rayDirection)
  if along < 0 then return nil end
  local closest = rayOrigin + rayDirection * along
  if (center - closest):squaredLength() <= radius * radius then return along end
  return nil
end

local nonTreeAssetTerms = {
  "shrub", "bush", "hedge", "grass", "fern", "flower", "weed",
  "groundcover", "ground_cover", "reed", "vine", "cactus", "agave"
}

local treeAssetWords = {
  tree = true, trees = true, pine = true, fir = true, spruce = true,
  cedar = true, oak = true, palm = true, fanpalm = true, birch = true,
  maple = true, willow = true, poplar = true, aspen = true, cypress = true,
  redwood = true, sequoia = true, eucalyptus = true, acacia = true,
  baobab = true, mesquite = true, sycamore = true, beech = true,
  elm = true, alder = true, linden = true, mangrove = true
}

local function isTreeAsset(shapePath)
  local path = string.lower(tostring(shapePath or "")):gsub("\\", "/")
  if path == "" then return false end
  for _, term in ipairs(nonTreeAssetTerms) do
    if path:find(term, 1, true) then return false end
  end
  -- Only classify words in the asset filename. A generic folder such as
  -- /trees/ is not proof by itself because BeamNG stores shrubs there too.
  local filename = path:match("([^/]+)$") or path
  for word in filename:gmatch("[a-z]+") do
    if treeAssetWords[word] then return true end
  end
  return false
end

local function treeAnchorFromBounds(itemPosition, worldBox)
  local minExtents = worldBox and worldBox.minExtents
  local maxExtents = worldBox and worldBox.maxExtents
  if not itemPosition or not minExtents or not maxExtents then return nil end
  local height = maxExtents.z - minExtents.z
  if height < forestMinimumHeight then return nil end
  local baseZ = math.max(itemPosition.z, minExtents.z)
  local anchorHeight = math.min(forestAnchorHeight, height * 0.5)
  return vec3(itemPosition.x, itemPosition.y, baseZ + anchorHeight)
end

local function forestMarkerAtRay(rayOrigin, rayDirection, cameraPos)
  if not core_forest or not core_forest.getForestObject then return nil end
  local forest = core_forest.getForestObject()
  if not forest or not forest.castRayRendered then return nil end

  local ok, hit = pcall(function()
    return forest:castRayRendered(rayOrigin, rayOrigin + rayDirection * selectionRange)
  end)
  local item = ok and hit and hit.forestItem or nil
  if not item then return nil end

  local okPosition, itemPosition = pcall(function() return item:getPosition() end)
  local okBox, worldBox = pcall(function() return item:getWorldBox() end)
  if not okPosition or not itemPosition or not okBox or not worldBox then return nil end

  local data = item.getData and item:getData() or nil
  local shapePath = data and data.getShapeFile and data:getShapeFile() or ""
  if not isTreeAsset(shapePath) then return nil end
  local worldPos = treeAnchorFromBounds(itemPosition, worldBox)
  if not worldPos then return nil end
  if (worldPos - cameraPos):squaredLength() > selectionRange * selectionRange then return nil end

  local uid = item.getUid and item:getUid() or 0
  local key = item.getKey and item:getKey() or tostring(itemPosition)
  return {
    kind = "static",
    staticId = uid ~= 0 and ("forestUid:" .. tostring(uid)) or ("forestKey:" .. tostring(key)),
    vehicleName = "Tree",
    pointKey = "staticAnchor",
    pointLabel = "Trunk",
    worldPos = worldPos,
    radius = clampValue((worldPos - cameraPos):length() * 0.01, 0.18, 0.32),
    hitDistance = (itemPosition - rayOrigin):length()
  }
end

local function placedTreeMarkerAtRay(rayOrigin, cameraPos)
  if not cameraMouseRayCast or not SOTStaticShape then return nil end

  local ok, hit = pcall(cameraMouseRayCast, true, SOTStaticShape, selectionRange)
  if not ok or not hit then
    ok, hit = pcall(cameraMouseRayCast, false, SOTStaticShape, selectionRange)
  end
  local object = ok and hit and hit.object or nil
  if not object or not object.getClassName or object:getClassName() ~= "TSStatic" then return nil end

  local okShape, shapePath = pcall(function() return object:getField("shapeName", 0) end)
  if not okShape or not isTreeAsset(shapePath) then return nil end
  local okPosition, objectPosition = pcall(function() return object:getPosition() end)
  local okBox, worldBox = pcall(function() return object:getWorldBox() end)
  if not okPosition or not okBox then return nil end
  local worldPos = treeAnchorFromBounds(objectPosition, worldBox)
  if not worldPos or (worldPos - cameraPos):squaredLength() > selectionRange * selectionRange then return nil end

  local objectId = object:getId()
  local hitPosition = hit.pos and vec3(hit.pos.x, hit.pos.y, hit.pos.z) or objectPosition
  return {
    kind = "static",
    staticId = "sceneObject:" .. tostring(objectId),
    vehicleName = "Tree",
    pointKey = "staticAnchor",
    pointLabel = "Trunk",
    worldPos = worldPos,
    radius = clampValue((worldPos - cameraPos):length() * 0.01, 0.18, 0.32),
    hitDistance = (hitPosition - rayOrigin):length()
  }
end

local function endpointMatchesMarker(endpoint, marker)
  if not endpoint or not marker or endpoint.kind ~= marker.kind then return false end
  if endpoint.kind == "static" then return endpoint.staticId == marker.staticId end
  return endpoint.vehicleId == marker.vehicleId and endpoint.pointKey == marker.pointKey
end

local function updateVisibleMarkers()
  table.clear(visibleMarkers)
  hoveredMarker = nil
  if state ~= STATE_SELECTING_FIRST and state ~= STATE_SELECTING_SECOND then return end
  if not core_camera or not core_camera.getPosition then return end

  local rawCameraPos = core_camera.getPosition()
  if not rawCameraPos then return end
  local cameraPos = vec3(rawCameraPos.x, rawCameraPos.y, rawCameraPos.z)
  local rangeSquared = selectionRange * selectionRange

  for _, veh in ipairs(getAllVehicles()) do
    local active = not veh.getActive or veh:getActive()
    if active and veh:getNodeCount() > 0 and (veh:getPosition() - cameraPos):squaredLength() <= (selectionRange + 10) ^ 2 then
      local box = getVehicleBox(veh)
      if box then
        for _, pointKey in ipairs(pointOrder) do
          local worldPos = pointWorldPosition(veh, box, pointKey)
          if worldPos and (worldPos - cameraPos):squaredLength() <= rangeSquared then
            local distance = (worldPos - cameraPos):length()
            local radius = clampValue(distance * 0.01, 0.16, 0.30)
            table.insert(visibleMarkers, {
              kind = "vehicle",
              vehicleId = veh:getID(),
              vehicleName = box.model,
              refNodeId = box.refNodeId,
              pointKey = pointKey,
              pointLabel = pointLabels[pointKey],
              worldPos = worldPos,
              radius = radius,
              box = box,
              vehicle = veh
            })
          end
        end
      end
    end
  end

  local ray = getCameraMouseRay and getCameraMouseRay()
  if not ray then return end
  local rayOrigin = vec3(ray.pos.x, ray.pos.y, ray.pos.z)
  local rayDirection = vec3(ray.dir.x, ray.dir.y, ray.dir.z)
  if rayDirection:squaredLength() < 1e-8 then return end
  rayDirection:normalize()

  local bestDistance = math.huge
  for _, marker in ipairs(visibleMarkers) do
    local hitDistance = raySphereDistance(rayOrigin, rayDirection, marker.worldPos, marker.radius * 1.35)
    if hitDistance and hitDistance < bestDistance then
      bestDistance = hitDistance
      hoveredMarker = marker
    end
  end


  -- Forest ray picking lets the player aim anywhere on a rendered tree while
  -- keeping the actual cable point low on its trunk.
  local forestMarker = forestMarkerAtRay(rayOrigin, rayDirection, cameraPos)
  if forestMarker then
    table.insert(visibleMarkers, forestMarker)
    if forestMarker.hitDistance < bestDistance then
      bestDistance = forestMarker.hitDistance
      hoveredMarker = forestMarker
    end
  end

  local placedTreeMarker = placedTreeMarkerAtRay(rayOrigin, cameraPos)
  if placedTreeMarker then
    table.insert(visibleMarkers, placedTreeMarker)
    if placedTreeMarker.hitDistance < bestDistance then
      bestDistance = placedTreeMarker.hitDistance
      hoveredMarker = placedTreeMarker
    end
  end

  -- Keep a previously selected static point visible while choosing endpoint B.
  if endpointA and endpointA.kind == "static"
    and (not forestMarker or forestMarker.staticId ~= endpointA.staticId)
    and (not placedTreeMarker or placedTreeMarker.staticId ~= endpointA.staticId) then
    table.insert(visibleMarkers, {
      kind = "static",
      staticId = endpointA.staticId,
      vehicleName = endpointA.vehicleName,
      pointKey = endpointA.pointKey,
      pointLabel = endpointA.pointLabel,
      worldPos = endpointA.worldPosition,
      radius = 0.22
    })
  end
end

local function drawSelectionMarkers()
  for _, marker in ipairs(visibleMarkers) do
    local color = markerColor
    if hoveredMarker == marker then
      color = markerHoverColor
    elseif endpointMatchesMarker(endpointA, marker) then
      color = markerSelectedColor
    end
    debugDrawer:drawSphere(marker.worldPos, marker.radius, color, true)
  end
end

local function queueVehicleCommand(vehicleId, command)
  local veh = getVehicle(vehicleId)
  if veh then veh:queueLuaCommand(command) end
end

local function ensureVehicleHelper(endpoint)
  if not endpoint or endpoint.kind ~= "vehicle" then return end
  local command = string.format(
    'if not extensions.rlsYankemVehicle then extensions.load("rlsYankemVehicle") end; if extensions.rlsYankemVehicle then extensions.rlsYankemVehicle.reportProperties(%d) end',
    connectionSerial
  )
  queueVehicleCommand(endpoint.vehicleId, command)
end

local function setEndpointSound(direction)
  if state ~= STATE_CONNECTED then direction = 0 end
  local command = string.format(
    'if extensions.rlsYankemVehicle then extensions.rlsYankemVehicle.setSoundDirection(%d) end',
    direction
  )
  if endpointA and endpointA.kind == "vehicle" then queueVehicleCommand(endpointA.vehicleId, command) end
  if endpointB and endpointB.kind == "vehicle" then queueVehicleCommand(endpointB.vehicleId, command) end
end

local function clearEndpointPhysics(endpoint)
  if not endpoint or endpoint.kind ~= "vehicle" then return end
  queueVehicleCommand(endpoint.vehicleId,
    'if extensions.rlsYankemVehicle then extensions.rlsYankemVehicle.clearWrench(); extensions.rlsYankemVehicle.setSoundDirection(0) end')
end

local function clearEndpointWrench(endpoint)
  if not endpoint or endpoint.kind ~= "vehicle" then return end
  queueVehicleCommand(endpoint.vehicleId,
    'if extensions.rlsYankemVehicle then extensions.rlsYankemVehicle.clearWrench() end')
end

local function applyEndpointWrench(endpoint, force, worldPoint, ttl, requestedAngularAccelCap)
  if not endpoint or endpoint.kind ~= "vehicle" then return end
  local command = string.format(
    'if extensions.rlsYankemVehicle then extensions.rlsYankemVehicle.applyWrench(%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g) end',
    force.x, force.y, force.z,
    worldPoint.x, worldPoint.y, worldPoint.z,
    ttl, requestedAngularAccelCap or angularAccelCap
  )
  queueVehicleCommand(endpoint.vehicleId, command)
end

local function clearAppliedForce()
  if not forceWasApplied then return end
  -- Tension may disappear while a reel input is still held, especially
  -- during payout. Sound follows the input lifetime, not cable load.
  clearEndpointWrench(endpointA)
  clearEndpointWrench(endpointB)
  forceWasApplied = false
end

local function resetConnectionState(reason)
  clearAppliedForce()
  clearEndpointPhysics(endpointA)
  clearEndpointPhysics(endpointB)
  endpointA = nil
  endpointB = nil
  endpointProperties = {}
  targetLength = 0
  currentLength = 0
  currentTension = 0
  reelDirection = 0
  isTaut = false
  lastLength = nil
  currentStretch = 0
  currentSeparationRate = 0
  currentEffectiveMass = 0
  currentSpringStiffness = 0
  currentDamping = 0
  currentControllerForce = 0
  currentLinearAccelCap = baseLinearAccelCap
  constraintEngaged = false
  hoveredMarker = nil
  table.clear(visibleMarkers)
  disconnectReason = reason
end

local function enterIdle(reason)
  resetConnectionState(reason)
  state = STATE_IDLE
  notifyUi()
end

local function beginSelection()
  resetConnectionState(nil)
  state = STATE_SELECTING_FIRST
  notifyUi()
end

local function connectEndpoints()
  local posA = endpointWorldPosition(endpointA)
  local posB = endpointWorldPosition(endpointB)
  if not posA or not posB then
    enterIdle("invalidEndpoint")
    return false
  end

  local length = (posB - posA):length()
  if length > maxCableLength then
    endpointB = nil
    shortMessage("Winch points must be within 30 m.", "warning")
    notifyUi()
    return false
  end

  connectionSerial = connectionSerial + 1
  targetLength = clampValue(length, minCableLength, maxCableLength)
  currentLength = length
  lastLength = length
  currentTension = 0
  reelDirection = 0
  isTaut = false
  currentStretch = 0
  currentSeparationRate = 0
  currentEffectiveMass = 0
  currentSpringStiffness = 0
  currentDamping = 0
  currentControllerForce = 0
  currentLinearAccelCap = baseLinearAccelCap
  constraintEngaged = false
  endpointProperties = {}
  state = STATE_CONNECTED
  hoveredMarker = nil
  table.clear(visibleMarkers)
  ensureVehicleHelper(endpointA)
  ensureVehicleHelper(endpointB)
  shortMessage("Winch connected", "link")
  notifyUi()
  return true
end

local function selectMarker(marker)
  if not marker then return false end
  if state == STATE_SELECTING_FIRST then
    endpointA = makeEndpointFromMarker(marker)
    state = STATE_SELECTING_SECOND
    notifyUi()
    return true
  end

  if state == STATE_SELECTING_SECOND then
    if endpointA and endpointA.kind == "static" and marker.kind == "static" then
      shortMessage("At least one winch point must be on a vehicle.", "warning")
      return false
    end
    if endpointA and endpointA.kind == "vehicle" and marker.kind == "vehicle"
      and endpointA.vehicleId == marker.vehicleId then
      shortMessage("Select a point on a different vehicle.", "warning")
      return false
    end
    endpointB = makeEndpointFromMarker(marker)
    return connectEndpoints()
  end
  return false
end

local function updateCablePhysics(dt)
  local posA = endpointWorldPosition(endpointA)
  local posB = endpointWorldPosition(endpointB)
  if not posA or not posB then
    enterIdle("endpointMissing")
    return
  end

  if reelDirection < 0 then
    targetLength = math.max(minCableLength, targetLength - spoolSpeed * dt)
  elseif reelDirection > 0 then
    targetLength = math.min(maxCableLength, targetLength + spoolSpeed * dt)
  end

  local cable = posB - posA
  currentLength = cable:length()
  if currentLength < 1e-5 then
    currentTension = 0
    isTaut = false
    currentStretch = 0
    currentSeparationRate = 0
    currentEffectiveMass = 0
    currentSpringStiffness = 0
    currentDamping = 0
    currentControllerForce = 0
    currentLinearAccelCap = baseLinearAccelCap
    constraintEngaged = false
    clearAppliedForce()
    lastLength = currentLength
    return
  end

  currentSeparationRate = 0
  if lastLength and dt > 1e-5 and dt < 0.25 then
    currentSeparationRate = (currentLength - lastLength) / dt
  end
  lastLength = currentLength

  local cableError = currentLength - targetLength
  currentStretch = math.max(cableError, 0)
  currentTension = 0
  currentControllerForce = 0
  currentEffectiveMass = 0
  currentSpringStiffness = 0
  currentDamping = 0

  if reelDirection > 0 or cableError < -constraintReleaseSlack then
    constraintEngaged = false
  elseif cableError > 0 then
    constraintEngaged = true
  end

  if reelDirection < 0 and constraintEngaged and currentSeparationRate > -stallClosingSpeed then
    currentLinearAccelCap = math.min(
      linearAccelCap,
      currentLinearAccelCap + pullAuthorityRampRate * dt
    )
  elseif reelDirection == 0 then
    currentLinearAccelCap = baseLinearAccelCap
  else
    currentLinearAccelCap = math.max(
      baseLinearAccelCap,
      currentLinearAccelCap - pullAuthorityReleaseRate * dt
    )
  end

  local propsA = endpointA.kind == "static" and {mass = math.huge} or endpointProperties[endpointA.vehicleId]
  local propsB = endpointB.kind == "static" and {mass = math.huge} or endpointProperties[endpointB.vehicleId]
  if propsA and propsB and propsA.mass and propsB.mass then
    local inverseMass = 0
    if endpointA.kind ~= "static" then inverseMass = inverseMass + 1 / propsA.mass end
    if endpointB.kind ~= "static" then inverseMass = inverseMass + 1 / propsB.mass end

    if inverseMass > 0 then
      currentEffectiveMass = 1 / inverseMass
      currentSpringStiffness = clampValue(
        currentEffectiveMass * controllerAngularFrequency * controllerAngularFrequency,
        minSpringStiffness,
        maxSpringStiffness
      )
      currentDamping = 2 * dampingRatio * math.sqrt(currentSpringStiffness * currentEffectiveMass)

      if constraintEngaged then
        local positiveForceLimit = math.min(
          maxTension,
          propsA.mass * currentLinearAccelCap,
          propsB.mass * currentLinearAccelCap
        )
        local negativeForceLimit = currentEffectiveMass * constraintAccelCap
        currentControllerForce = clampValue(
          currentSpringStiffness * cableError + currentDamping * currentSeparationRate,
          -negativeForceLimit,
          positiveForceLimit
        )
        currentTension = math.max(currentControllerForce, 0)
      end
    end
  end

  isTaut = constraintEngaged and (math.abs(currentControllerForce) > 1 or currentStretch > tautEpsilon)
  if math.abs(currentControllerForce) > 1 then
    local direction = cable / currentLength
    local forceA = direction * currentControllerForce
    local ttl = math.max(dt * 2.5, 0.05)
    local activeAngularAccelCap = reelDirection == 0 and holdAngularAccelCap or angularAccelCap
    applyEndpointWrench(endpointA, forceA, posA, ttl, activeAngularAccelCap)
    applyEndpointWrench(endpointB, -forceA, posB, ttl, activeAngularAccelCap)
    forceWasApplied = true
  else
    clearAppliedForce()
  end
end

local function drawCable()
  local posA = endpointWorldPosition(endpointA)
  local posB = endpointWorldPosition(endpointB)
  if not posA or not posB then return end

  local color = cableSlackColor
  if reelDirection ~= 0 then
    color = cableReelingColor
  elseif isTaut then
    color = cableTensionColor
  end
  debugDrawer:drawLine(posA, posB, color)
  debugDrawer:drawSphere(posA, 0.09, color, true)
  debugDrawer:drawSphere(posB, 0.09, color, true)
end

function M.toggleWinch()
  if state == STATE_IDLE then
    beginSelection()
  elseif state == STATE_CONNECTED then
    M.disconnect("user")
  else
    enterIdle("cancelled")
  end
end

function M.selectAtCursor()
  if state ~= STATE_SELECTING_FIRST and state ~= STATE_SELECTING_SECOND then return false end
  -- Do not select through the controller or another CEF UI surface. The raw
  -- mouse binding remains additive with BeamNG's normal world interactions.
  if core_vehicleTriggers and core_vehicleTriggers.state
    and core_vehicleTriggers.state.cefMouseCaptured then return false end
  updateVisibleMarkers()
  return selectMarker(hoveredMarker)
end

function M.setReelDirection(direction)
  direction = tonumber(direction) or 0
  direction = direction < 0 and -1 or (direction > 0 and 1 or 0)
  if state ~= STATE_CONNECTED then direction = 0 end
  if reelDirection == direction then return end
  reelDirection = direction
  setEndpointSound(direction)
  notifyUi()
end

function M.disconnect(reason)
  enterIdle(reason or "user")
end

function M.receiveVehicleProperties(vehicleId, serial, properties)
  if state ~= STATE_CONNECTED or serial ~= connectionSerial then return end
  if not endpointA or not endpointB then return end
  if vehicleId ~= endpointA.vehicleId and vehicleId ~= endpointB.vehicleId then return end
  if type(properties) ~= "table" or not properties.mass or properties.mass <= 0 then return end
  endpointProperties[vehicleId] = properties
  notifyUi()
end

function M.getUiState()
  local readyA = endpointA and (endpointA.kind == "static" or endpointProperties[endpointA.vehicleId] ~= nil)
  local readyB = endpointB and (endpointB.kind == "static" or endpointProperties[endpointB.vehicleId] ~= nil)
  local ready = readyA and readyB
  local instruction = ""
  if state == STATE_SELECTING_FIRST then
    instruction = "Select a vehicle point or tree"
  elseif state == STATE_SELECTING_SECOND then
    instruction = "Select a vehicle point or tree"
  elseif state == STATE_CONNECTED then
    instruction = ready and "Winch connected" or "Preparing winch..."
  end

  return {
    available = state ~= STATE_IDLE,
    state = state,
    instruction = instruction,
    endpointA = endpointA and {
      kind = endpointA.kind,
      vehicleId = endpointA.vehicleId,
      vehicleName = endpointA.vehicleName,
      pointKey = endpointA.pointKey,
      pointLabel = endpointA.pointLabel
    } or nil,
    endpointB = endpointB and {
      kind = endpointB.kind,
      vehicleId = endpointB.vehicleId,
      vehicleName = endpointB.vehicleName,
      pointKey = endpointB.pointKey,
      pointLabel = endpointB.pointLabel
    } or nil,
    currentLength = currentLength,
    targetLength = targetLength,
    tension = currentTension,
    taut = isTaut,
    reelDirection = reelDirection,
    ready = ready == true,
    markerCount = #visibleMarkers,
    disconnectReason = disconnectReason
  }
end

function M.getDebugState()
  local result = M.getUiState()
  result.connectionSerial = connectionSerial
  result.forceApplied = forceWasApplied
  result.stretch = currentStretch
  result.separationRate = currentSeparationRate
  result.effectiveMass = currentEffectiveMass
  result.springStiffness = currentSpringStiffness
  result.damping = currentDamping
  result.controllerForce = currentControllerForce
  result.linearAccelCap = currentLinearAccelCap
  result.constraintEngaged = constraintEngaged
  result.hovered = hoveredMarker and {
    kind = hoveredMarker.kind,
    staticId = hoveredMarker.staticId,
    vehicleId = hoveredMarker.vehicleId,
    pointKey = hoveredMarker.pointKey
  } or nil
  return result
end

function M.getVehiclePoints(vehicleId)
  local veh = getVehicle(vehicleId)
  local box = getVehicleBox(veh)
  if not box then return nil end
  local result = {}
  for _, pointKey in ipairs(pointOrder) do
    local world = pointWorldPosition(veh, box, pointKey)
    result[pointKey] = world and vecToTable(world) or nil
  end
  return result
end

function M.debugConnect(vehicleIdA, pointKeyA, vehicleIdB, pointKeyB)
  local vehA, vehB = getVehicle(vehicleIdA), getVehicle(vehicleIdB)
  if not vehA or not vehB or vehicleIdA == vehicleIdB then return false end
  local boxA, boxB = getVehicleBox(vehA), getVehicleBox(vehB)
  if not boxA or not boxB or not boxA.points[pointKeyA] or not boxB.points[pointKeyB] then return false end
  resetConnectionState(nil)
  endpointA = makeEndpoint(vehA, boxA, pointKeyA)
  endpointB = makeEndpoint(vehB, boxB, pointKeyB)
  return connectEndpoints()
end

function M.debugConnectStatic(vehicleId, pointKey, x, y, z)
  local veh = getVehicle(vehicleId)
  local box = getVehicleBox(veh)
  if not veh or not box or not box.points[pointKey] then return false end
  resetConnectionState(nil)
  endpointA = makeEndpoint(veh, box, pointKey)
  endpointB = {
    kind = "static",
    vehicleName = "World anchor",
    pointKey = "staticAnchor",
    pointLabel = "Anchor",
    staticId = "debugStatic",
    worldPosition = vec3(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
  }
  return connectEndpoints()
end

function M.debugIsTreeAsset(shapePath)
  return isTreeAsset(shapePath)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local renderDt = tonumber(dtReal) or 0
  local physicsDt = tonumber(dtSim) or 0

  if state == STATE_CONNECTED then
    updateCablePhysics(math.max(physicsDt, 0))
  end

  uiTimer = uiTimer + math.max(renderDt, 0)
  if state ~= STATE_IDLE and uiTimer >= 0.1 then
    uiTimer = 0
    notifyUi()
  end
end

-- DebugDrawer commands are submitted immediately before rendering so their
-- endpoints use the latest interpolated vehicle and camera transforms. Cable
-- physics intentionally remains in onUpdate; this hook is visual-only.
local function onPreRender()
  if state == STATE_SELECTING_FIRST or state == STATE_SELECTING_SECOND then
    updateVisibleMarkers()
    drawSelectionMarkers()
  elseif state == STATE_CONNECTED then
    drawCable()
  end
end

local function invalidateVehicle(vehicleId, reason)
  boxCache[vehicleId] = nil
  if (endpointA and endpointA.vehicleId == vehicleId) or (endpointB and endpointB.vehicleId == vehicleId) then
    enterIdle(reason)
  end
end

local function onVehicleResetted(vehicleId)
  invalidateVehicle(vehicleId, "vehicleReset")
end

local function onVehicleDestroyed(vehicleId)
  invalidateVehicle(vehicleId, "vehicleDestroyed")
end

local function onVehicleSpawned(vehicleId)
  boxCache[vehicleId] = nil
end

local function cleanup(reason)
  if state ~= STATE_IDLE or endpointA or endpointB then
    enterIdle(reason)
  end
end

local function onClientEndMission()
  cleanup("levelEnded")
  table.clear(boxCache)
end

local function onExtensionLoaded()
  log("I", logTag, "Project Yankem loaded")
  notifyUi()
end

local function onExtensionUnloaded()
  cleanup("extensionUnloaded")
  log("I", logTag, "Project Yankem unloaded")
end

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleSpawned = onVehicleSpawned
M.onClientEndMission = onClientEndMission
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
