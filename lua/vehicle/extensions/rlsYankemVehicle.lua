-- Vehicle-side Project Yankem physics and sound helper.

local M = {}

local refNodeId = 0
local properties
local propertiesAge = math.huge
local soundSource
local soundDirection = 0
local soundVolume = 0
local soundPitch = 1

local soundEvent = "event:>Vehicle>Hydraulics>Pump_Small_01"
local soundTargetVolume = 0.2
local propertyRefreshInterval = 0.1
local linearAccelCap = 250

local function clampMagnitude(vector, maximum)
  local length = vector:length()
  if length > maximum and length > 1e-9 then
    return vector * (maximum / length)
  end
  return vector
end

local function getReferenceNodeId()
  local refs = v.data.refNodes and v.data.refNodes[0]
  return refs and (refs.ref or refs.cid) or 0
end

local function nodeBelongsToReferenceCluster(cid, referenceCluster)
  if referenceCluster == nil then return true end
  local ok, clusterId = pcall(function() return obj:getNodeClusterId(cid) end)
  return not ok or clusterId == referenceCluster
end

local function computeMassProperties()
  refNodeId = getReferenceNodeId()
  local referenceCluster
  local ok, clusterId = pcall(function() return obj:getNodeClusterId(refNodeId) end)
  if ok then referenceCluster = clusterId end

  local mass = 0
  local weightedCog = vec3(0, 0, 0)
  local nodes = {}

  for _, node in pairs(v.data.nodes or {}) do
    local cid = node.cid
    if cid ~= nil and nodeBelongsToReferenceCluster(cid, referenceCluster) then
      local nodeMass = obj:getNodeMass(cid)
      local position = obj:getAbsNodePosition(cid)
      if nodeMass and nodeMass > 0 and position then
        mass = mass + nodeMass
        weightedCog = weightedCog + position * nodeMass
        table.insert(nodes, {mass = nodeMass, position = position})
      end
    end
  end

  if mass <= 0 then return nil end
  local cog = weightedCog / mass
  local xx, yy, zz, xy, xz, yz = 0, 0, 0, 0, 0, 0

  for _, node in ipairs(nodes) do
    local r = node.position - cog
    local nodeMass = node.mass
    xx = xx + nodeMass * (r.y * r.y + r.z * r.z)
    yy = yy + nodeMass * (r.x * r.x + r.z * r.z)
    zz = zz + nodeMass * (r.x * r.x + r.y * r.y)
    xy = xy - nodeMass * r.x * r.y
    xz = xz - nodeMass * r.x * r.z
    yz = yz - nodeMass * r.y * r.z
  end

  properties = {
    mass = mass,
    cog = cog,
    inertia = {xx = xx, yy = yy, zz = zz, xy = xy, xz = xz, yz = yz},
    nodeCount = #nodes
  }
  propertiesAge = 0
  return properties
end

local function inverseInertiaMultiply(inertia, torque)
  local a, b, c = inertia.xx, inertia.xy, inertia.xz
  local d, e = inertia.yy, inertia.yz
  local f = inertia.zz
  local det = a * (d * f - e * e) - b * (b * f - e * c) + c * (b * e - d * c)
  if math.abs(det) < 1e-6 then return vec3(0, 0, 0) end

  local invDet = 1 / det
  local ixx = (d * f - e * e) * invDet
  local ixy = (c * e - b * f) * invDet
  local ixz = (b * e - c * d) * invDet
  local iyy = (a * f - c * c) * invDet
  local iyz = (b * c - a * e) * invDet
  local izz = (a * d - b * b) * invDet

  return vec3(
    ixx * torque.x + ixy * torque.y + ixz * torque.z,
    ixy * torque.x + iyy * torque.y + iyz * torque.z,
    ixz * torque.x + iyz * torque.y + izz * torque.z
  )
end

local function ensureSound()
  if soundSource then return end
  soundSource = obj:createSFXSource2(soundEvent, "AudioDefaultLoop3D", "rlsYankemPump", refNodeId, 0)
  if soundSource then
    obj:setVolumePitchCT(soundSource, 0, 1, 0, 0)
    obj:playSFX(soundSource)
  end
end

local function stopSound()
  soundDirection = 0
  soundVolume = 0
  if soundSource then
    obj:setVolumePitchCT(soundSource, 0, soundPitch, 0, 0)
  end
end

function M.reportProperties(serial)
  local props = computeMassProperties()
  if not props then return end
  local payload = {
    mass = props.mass,
    nodeCount = props.nodeCount,
    cog = {props.cog.x, props.cog.y, props.cog.z}
  }
  obj:queueGameEngineLua(string.format(
    "if extensions.rlsYankem then extensions.rlsYankem.receiveVehicleProperties(%d,%d,%s) end",
    obj:getId(), tonumber(serial) or -1, serialize(payload)
  ))
end

function M.applyWrench(forceX, forceY, forceZ, pointX, pointY, pointZ, ttl, requestedAngularCap)
  if not properties or propertiesAge >= propertyRefreshInterval then
    computeMassProperties()
  end
  if not properties or properties.mass <= 0 then return end

  local force = vec3(forceX or 0, forceY or 0, forceZ or 0)
  local linearAcceleration = clampMagnitude(force / properties.mass, linearAccelCap)
  local point = vec3(pointX or 0, pointY or 0, pointZ or 0)
  local torque = (point - properties.cog):cross(force)
  local angularAcceleration = inverseInertiaMultiply(properties.inertia, torque)
  angularAcceleration = clampMagnitude(angularAcceleration, tonumber(requestedAngularCap) or 8)

  thrusters.applyAccel(linearAcceleration, math.max(tonumber(ttl) or 0.05, 0.01), refNodeId, angularAcceleration)
end

function M.clearWrench()
  refNodeId = getReferenceNodeId()
  thrusters.applyAccel(vec3(0, 0, 0), 0.02, refNodeId, vec3(0, 0, 0))
end

function M.setSoundDirection(direction)
  direction = tonumber(direction) or 0
  soundDirection = direction < 0 and -1 or (direction > 0 and 1 or 0)
  if soundDirection ~= 0 then ensureSound() end
end

local function updateGFX(dt)
  propertiesAge = propertiesAge + dt
  local targetVolume = soundDirection == 0 and 0 or soundTargetVolume
  local targetPitch = soundDirection > 0 and 0.8 or 1.0
  local volumeStep = math.max(dt, 0) * 10
  local pitchStep = math.max(dt, 0) * 5

  soundVolume = soundVolume + math.max(-volumeStep, math.min(volumeStep, targetVolume - soundVolume))
  soundPitch = soundPitch + math.max(-pitchStep, math.min(pitchStep, targetPitch - soundPitch))

  if soundSource then
    obj:setVolumePitchCT(soundSource, soundVolume, soundPitch, soundDirection == 0 and 0 or 1, 0)
  end
end

local function reset()
  refNodeId = getReferenceNodeId()
  properties = nil
  propertiesAge = math.huge
  M.clearWrench()
  stopSound()
end

local function onExtensionLoaded()
  refNodeId = getReferenceNodeId()
  computeMassProperties()
end

local function onExtensionUnloaded()
  M.clearWrench()
  stopSound()
  if soundSource then obj:stopSFX(soundSource) end
  soundSource = nil
end

M.updateGFX = updateGFX
M.onReset = reset
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
