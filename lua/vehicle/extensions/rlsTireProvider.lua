-- RLS Career Overhaul tire provider.
-- The thermal/wear behavior is derived from Tyre Wear and Thermals Redux by
-- ZestyMaple98 and is distributed under AGPLv3; see licenses/tyre-thermals-AGPL-3.0.txt.
local M = {}

local tireModel = require("rls_tire_model")

local PROVIDER_VERSION = "1.3.0"
local REPORT_INTERVAL = 2
local TELEMETRY_INTERVAL = 0.2
local WATER_CHECK_INTERVAL = 0.05
local BASE_DISTANCE_WEAR_PER_METER = 1.864e-9
local BASE_SLIP_WEAR_PER_JOULE = 4.0e-9

local context = {
  enabled = false,
  ambientTemperature = 21,
  initialState = {},
  groundModels = {},
  roadWetness = 0,
  wetGripMultipliers = {},
  wetGroundModels = {},
}
local wheelStates = {}
local wheelCache = {}
local vehicleMass = 1000
local reportTimer = 0
local telemetryTimer = TELEMETRY_INTERVAL
local providerCheckTimer = 0
local waterCheckTimer = 0
local selectedProvider = "bundled"
local lastProviderKey
local configuredInventoryId
local configuredStateRevision
local configured = false
local gripApplied = false
local telemetrySequence = 0
local telemetrySession = tostring(obj:getID()) .. ":" .. tostring(os.clock())

local function sendTelemetry(payload)
  telemetrySequence = telemetrySequence + 1
  payload.session = telemetrySession
  payload.sequence = telemetrySequence
  gui.send("RlsTireWearThermals", payload)
end

local function deepCopy(value)
  if type(deepcopy) == "function" then return deepcopy(value) end
  if type(value) ~= "table" then return value end
  local result = {}
  for key, nested in pairs(value) do result[key] = deepCopy(nested) end
  return result
end

local function averageTemperature(state)
  local temperature = state and state.temperature or nil
  if type(temperature) ~= "table" then return context.ambientTemperature end
  local total, count = 0, 0
  for index = 1, 3 do
    local value = tonumber(temperature[index])
    if value then
      total = total + value
      count = count + 1
    end
  end
  return count > 0 and total / count or context.ambientTemperature
end

local function wheelConfig(index)
  return v and v.data and v.data.wheels and v.data.wheels[index] or {}
end

local function activeTirePartForWheel(wheelName)
  local wheelAxle = string.sub(string.upper(tostring(wheelName or "")), 1, 1)
  local bestPath, bestName, bestScore
  for path, partName in pairs(v and v.data and v.data.activeParts or {}) do
    local lowerPath = string.lower(tostring(path))
    local lowerName = string.lower(tostring(partName))
    if string.sub(lowerName, 1, 5) == "tire_" then
      local score = 1
      if wheelAxle == "F" and (string.find(lowerName, "tire_f", 1, true) or
                                string.find(lowerPath, "/wheel_f", 1, true)) then
        score = score + 10
      elseif wheelAxle ~= "F" and (string.find(lowerName, "tire_r", 1, true) or
                                    string.find(lowerPath, "/wheel_r", 1, true)) then
        score = score + 10
      end
      if not bestScore or score > bestScore then
        bestPath, bestName, bestScore = tostring(path), tostring(partName), score
      end
    end
  end
  return bestPath, bestName
end

local function thermalBaseline(index)
  local cfg = wheelConfig(index)
  return {
    lowTemp = tonumber(cfg.frictionLowTemp) or -300,
    highTemp = tonumber(cfg.frictionHighTemp) or 1e7,
    lowSlope = tonumber(cfg.frictionLowSlope) or 1e-10,
    highSlope = tonumber(cfg.frictionHighSlope) or 1e-10,
    smooth = tonumber(cfg.frictionSlopeSmoothCoef) or 10,
    lowCoef = tonumber(cfg.frictionCoefLow) or 1,
    middleCoef = tonumber(cfg.frictionCoefMiddle) or 1,
    highCoef = tonumber(cfg.frictionCoefHigh) or 1,
  }
end

local function setWheelGrip(index, multiplier)
  local wheel = obj:getWheel(index)
  if not wheel then return end
  local baseline = wheelCache[index] and wheelCache[index].baseline or thermalBaseline(index)
  wheel:setFrictionThermalSensitivity(
    baseline.lowTemp,
    baseline.highTemp,
    baseline.lowSlope,
    baseline.highSlope,
    baseline.smooth,
    baseline.lowCoef * multiplier,
    baseline.middleCoef * multiplier,
    baseline.highCoef * multiplier
  )
end

local function restoreGrip()
  for index in pairs(wheelCache) do setWheelGrip(index, 1) end
  gripApplied = false
end

local function resetTemperatures()
  for _, state in pairs(wheelStates) do
    state.temperature = {
      context.ambientTemperature,
      context.ambientTemperature,
      context.ambientTemperature,
      context.ambientTemperature,
    }
  end
  for _, cached in pairs(wheelCache) do
    cached.inWater = nil
  end
  waterCheckTimer = 0
end

local function restoreSoftDeflation(index, rotator)
  if not rotator or rotator.isTireDeflated ~= true or rotator.isBroken == true then return false end
  local wheel = wheels and wheels.wheels and wheels.wheels[index] or rotator
  local cfg = wheelConfig(index)
  local pressureGroupId = wheel.pressureGroupId or
    (cfg.pressureGroup and v and v.data and v.data.pressureGroups and v.data.pressureGroups[cfg.pressureGroup])
  local startingPressure = tonumber(wheel.startingPressure)
  if pressureGroupId == nil or startingPressure == nil then return false end

  obj:setGroupPressure(pressureGroupId, startingPressure)
  wheel.isTireDeflated = false
  rotator.isTireDeflated = false
  return true
end

local function resetWheelBrokenBeams(wheelid)
  local fn = beamstate and beamstate.deflateTire
  if type(fn) ~= "function" or not debug or type(debug.getupvalue) ~= "function" then
    return
  end
  local i = 1
  while true do
    local name, value = debug.getupvalue(fn, i)
    if not name then
      break
    end
    if name == "wheelBrokenBeams" and type(value) == "table" then
      value[wheelid] = nil
      return
    end
    i = i + 1
  end
end

local function restoreBeamList(beamList)
  if type(beamList) ~= "table" or not v or not v.data or not v.data.beams then
    return
  end
  for _, beamcid in pairs(beamList) do
    local beam = v.data.beams[beamcid]
    if beam then
      obj:setBeamSpringDamp(beamcid, beam.beamSpring or 0, beam.beamDamp or 0, -1, -1)
    end
  end
end

local function restoreDeflatedTire(index, rotator)
  local dataWheel = v and v.data and v.data.wheels and v.data.wheels[index]
  local wheel = wheels and wheels.wheels and wheels.wheels[index] or rotator
  if not dataWheel or not rotator then
    return false
  end

  restoreSoftDeflation(index, rotator)
  if dataWheel.pressureGroup and v.data.pressureGroups and v.data.pressureGroups[dataWheel.pressureGroup] then
    local startingPressure = tonumber(wheel.startingPressure) or 200000
    obj:setGroupPressure(v.data.pressureGroups[dataWheel.pressureGroup], startingPressure)
  end

  if wheel then
    wheel.isTireDeflated = false
    wheel.isPunctured = false
  end
  rotator.isTireDeflated = false
  rotator.isPunctured = false
  resetWheelBrokenBeams(index)

  if damageTracker and damageTracker.setDamage then
    pcall(damageTracker.setDamage, "wheels", "tire" .. tostring(dataWheel.name or rotator.name or ""), false)
  end

  if dataWheel.treadNodes then
    for _, nodecid in pairs(dataWheel.treadNodes) do
      local node = v.data.nodes and v.data.nodes[nodecid]
      if node and node.frictionCoef then
        obj:setNodeFrictionSlidingCoefs(nodecid, node.frictionCoef, node.slidingFrictionCoef or node.frictionCoef)
      end
    end
  end
  restoreBeamList(dataWheel.treadBeams)
  restoreBeamList(dataWheel.sideBeams)
  restoreBeamList(dataWheel.peripheryBeams)
  restoreBeamList(dataWheel.reinfBeams)
  if dataWheel.pressuredBeams and v.data.beams then
    for _, beamcid in pairs(dataWheel.pressuredBeams) do
      local beam = v.data.beams[beamcid]
      if beam then
        local pressure = tonumber(beam.beamPressure) or tonumber(wheel.startingPressure) or 200000
        obj:setBeamPressureRel(beamcid, pressure, math.huge, -1, -1)
      end
    end
  end
  return true
end

local function getVehicleMass()
  local mass = 0
  for _, node in pairs(v and v.data and v.data.nodes or {}) do
    mass = mass + (tonumber(node.nodeWeight) or 0)
  end
  return math.max(mass, 1)
end

local function externalExtension()
  if not extensions or not extensions.isExtensionLoaded or
     not extensions.isExtensionLoaded("luukstyrethermalsandwear") then
    return nil
  end
  return extensions.luukstyrethermalsandwear
end

local function externalApi(ext)
  if not ext then return nil end
  local getInfo = ext.getRlsTireProviderInfo or ext.getRlsProviderInfo
  local configure = ext.configureRlsTireProvider or ext.setRlsContext
  local getState = ext.getRlsTireState or ext.getRlsState
  if type(getInfo) == "function" and type(configure) == "function" and type(getState) == "function" then
    return {
      getInfo = getInfo,
      configure = configure,
      getState = getState,
      restore = ext.restoreRlsThermalsAndGrip or ext.resetRlsThermalsAndGrip,
      flush = ext.flushRlsTireState or ext.flushRlsState,
      handlePartChanges = ext.handleRlsTirePartChanges or ext.onRlsTirePartChanges,
    }
  end
end

local function providerInfo()
  local ext = externalExtension()
  local api = externalApi(ext)
  if ext and api then
    local ok, info = pcall(api.getInfo)
    info = ok and type(info) == "table" and info or {}
    return {
      id = info.id or "external-tyre-thermals",
      name = info.name or "Tyre Wear and Thermals Redux",
      version = info.version or "unknown",
      apiVersion = tonumber(info.apiVersion) or 1,
      source = "external",
      integrated = true,
      capabilities = info.capabilities or {
        gating = true, persistence = true, exclusions = true, telemetry = true, replacement = true,
      },
    }
  elseif ext then
    return {
      id = "external-tyre-thermals-legacy",
      name = "Tyre Wear and Thermals Redux",
      version = "legacy/unknown",
      apiVersion = 0,
      source = "external",
      integrated = false,
      capabilities = {},
    }
  end
  return {
    id = "rls-bundled",
    name = "RLS Tyre Wear and Thermals",
    version = PROVIDER_VERSION,
    apiVersion = 1,
    source = "bundled",
    integrated = true,
    capabilities = {
      gating = true, persistence = true, exclusions = true, telemetry = true, replacement = true,
      weatherGrip = true,
    },
  }
end

local function detectProvider(force)
  local info = providerInfo()
  local nextProvider = tireModel.selectProvider(info.source == "external", info.integrated == true)
  if force or nextProvider ~= selectedProvider then
    if selectedProvider == "bundled" then restoreGrip() end
    selectedProvider = nextProvider
    lastProviderKey = nil
    if nextProvider == "external" then
      local api = externalApi(externalExtension())
      if api then pcall(api.configure, deepCopy(context)) end
    end
  end
  return info
end

local function materialName(materialId)
  if not particles or not particles.getMaterialsParticlesTable then return "unknown" end
  local materials = particles.getMaterialsParticlesTable()
  local row = materials and materials[materialId] or nil
  return row and row.name or "unknown"
end

local function groundModel(materialId)
  local name = materialName(materialId)
  return name, context.groundModels[name] or {staticFrictionCoefficient = 1, slidingFrictionCoefficient = 1}
end

local function makeState(index, rotator)
  local cfg = wheelConfig(index)
  local name = tostring(rotator.name or cfg.name or index)
  local saved = context.initialState and context.initialState[name] or nil
  local remaining = saved and tonumber(saved.remaining) or tonumber(context.defaultRemaining) or 1
  local working = 85 * tireModel.clamp(1.05 - (tonumber(rotator.treadCoef or cfg.treadCoef) or 0.7) * 0.1, 0.85, 1.05)
  return {
    name = name,
    remaining = tireModel.clamp(remaining, 0, 1),
    flat = saved and saved.flat == true or false,
    temperature = {
      context.ambientTemperature,
      context.ambientTemperature,
      context.ambientTemperature,
      context.ambientTemperature,
    },
    workingTemperature = working,
  }
end

local function cacheRotator(index, rotator)
  local cfg = wheelConfig(index)
  local cached = wheelCache[index] or {baseline = thermalBaseline(index)}
  local tirePartPath, tirePartName = activeTirePartForWheel(rotator.name or cfg.name)
  cached.name = tostring(rotator.name or cfg.name or index)
  cached.width = tonumber(cfg.tireWidth or rotator.tireWidth) or 0.205
  cached.radius = tonumber(rotator.radius or cfg.radius) or 0.3
  cached.partOrigin = tirePartName or cfg.partOrigin or rotator.partOrigin
  cached.partPath = tirePartPath or cfg.partPath or rotator.partPath or cached.partOrigin
  cached.containingSlot = tirePartPath and tirePartPath:match("^(.*[/])[^/]+$") or
                            cfg.containingSlot or rotator.containingSlot
  cached.baseFriction = tonumber(cfg.frictionCoef or rotator.frictionCoef) or 1
  cached.slidingFriction = tonumber(cfg.slidingFrictionCoef or rotator.slidingFrictionCoef) or cached.baseFriction
  cached.treadCoef = tonumber(rotator.treadCoef or cfg.treadCoef) or 0.7
  cached.compound = tireModel.classifyTireCompound(cached)
  wheelCache[index] = cached
  wheelStates[index] = wheelStates[index] or makeState(index, rotator)
  return cached, wheelStates[index]
end

local function updateTemperatures(state, cached, rotator, slipWork, speed, inWater, dt)
  local width = math.max(cached.width, 0.150)
  local heatGain = slipWork / (width * 850000)
  local skinAverage = averageTemperature(state)
  local brakeTemp = tonumber(rotator.brakeSurfaceTemperature) or context.ambientTemperature
  local waterCooling = tireModel.waterCoolingMultiplier(inWater)
  local cooling = (skinAverage - context.ambientTemperature) *
                    (0.0025 + math.sqrt(math.max(speed, 0)) * 0.0007) * waterCooling
  for ring = 1, 3 do
    local ringBias = ring == 2 and 1.05 or 0.975
    state.temperature[ring] = tireModel.temperatureWithAmbientFloor(
      state.temperature[ring] + (heatGain * ringBias - cooling) * dt,
      context.ambientTemperature)
  end
  local coreExchange = (skinAverage - state.temperature[4]) * 0.035
  local brakeExchange = (brakeTemp - state.temperature[4]) * 0.0015
  local coreCooling = (state.temperature[4] - context.ambientTemperature) *
                        (0.0015 + speed * 0.00015) * waterCooling
  state.temperature[4] = tireModel.temperatureWithAmbientFloor(
    state.temperature[4] + (coreExchange + brakeExchange - coreCooling) * dt,
    context.ambientTemperature)
end

local function updateBundled(dt, emitTelemetry, checkWater)
  if not wheels or not wheels.wheelRotators then return end
  local speed = obj:getVelocity():length()
  local wheelCount = math.max(#wheels.wheelRotators + 1, 1)
  local referenceLoad = vehicleMass * 9.81 / wheelCount
  local stream = emitTelemetry and {data = {}, provider = providerInfo(), enabled = context.enabled == true} or nil

  for index, rotator in pairs(wheels.wheelRotators) do
    local cached, state = cacheRotator(index, rotator)
    local wasFlat = state.flat == true
    local isPhysicallyFlat = rotator.isTireDeflated == true or rotator.isBroken == true
    if context.enabled then
      state.flat = state.flat or isPhysicallyFlat
      if state.flat and not isPhysicallyFlat then beamstate.deflateTire(index) end
    else
      restoreSoftDeflation(index, rotator)
      state.remaining = 1
      state.flat = false
    end

    local surfaceSpeed = math.abs(tonumber(rotator.angularVelocity) or 0) * cached.radius
    local rawThermalSlipSeverity, rawAbrasionSlipSeverity = tireModel.slipSeverities(
      rotator.lastSlip, rotator.lastSideSlip)
    local load = math.max(math.abs(tonumber(rotator.downForceRaw or rotator.downForce) or 0), 0)
    local groundName, ground = groundModel(rotator.contactMaterialID1)
    local surfaceTuning = tireModel.surfaceTireTuning(groundName)
    local thermalSlipSeverity = tireModel.smoothSlipCap(
      rawThermalSlipSeverity, surfaceTuning.thermalSlipCap)
    local abrasionSlipSeverity = tireModel.smoothSlipCap(
      rawAbrasionSlipSeverity, surfaceTuning.abrasionSlipCap)
    local thermalSlipSpeed = thermalSlipSeverity * math.max(surfaceSpeed, speed, 1) * 0.25
    local abrasionSlipSpeed = abrasionSlipSeverity * math.max(surfaceSpeed, speed, 1) * 0.25
    local weatherWetness = tireModel.wetnessForSurface(
      context.roadWetness, groundName, context.wetGroundModels)
    local weatherGrip, compound = tireModel.wetGripMultiplier(
      weatherWetness, cached, context.wetGripMultipliers)
    cached.compound = compound
    cached.weatherGrip = weatherGrip
    cached.weatherWetness = weatherWetness
    cached.contactMaterial = groundName
    local groundFriction = math.max(tonumber(ground.staticFrictionCoefficient) or 1, 0.1)
    local wheelFriction = (math.max(cached.baseFriction, 0.1) + math.max(cached.slidingFriction, 0.1)) * 0.5
    local tunedGrip = math.max(tonumber(cached.baseline and cached.baseline.middleCoef) or 1, 0.1)
    local inherentGrip = wheelFriction * tunedGrip
    local effectiveGrip = groundFriction * wheelFriction * tunedGrip * weatherGrip
    local thermalSlipWork = load * effectiveGrip * thermalSlipSpeed * surfaceTuning.thermalMultiplier
    local abrasionSlipWork = load * effectiveGrip * abrasionSlipSpeed * surfaceTuning.abrasionMultiplier
    if checkWater or cached.inWater == nil then cached.inWater = tireModel.wheelTouchesWater(rotator, obj) end

    local conditionGrip = 1
    if context.enabled then
      updateTemperatures(state, cached, rotator, thermalSlipWork, speed, cached.inWater, dt)
      local loadMultiplier = tireModel.clamp(load / math.max(referenceLoad, 1), 0.25, 3)
      local tireTemperature = averageTemperature(state)
      local temperatureMultiplier = tireModel.temperatureWearMultiplier(tireTemperature, state.workingTemperature)
      local overheatGripMultiplier = tireModel.overheatGripWearMultiplier(
        inherentGrip, tireTemperature, state.workingTemperature)
      local distanceWear = speed * BASE_DISTANCE_WEAR_PER_METER
      local slipWear = abrasionSlipWork * BASE_SLIP_WEAR_PER_JOULE
      local wear = tireModel.combineWearComponents(
        distanceWear, slipWear, loadMultiplier) * effectiveGrip *
                     tireModel.widthWearMultiplier(cached.width) * temperatureMultiplier *
                     overheatGripMultiplier * dt
      if context.readOnly ~= true then
        state.remaining = tireModel.clamp(state.remaining - wear, 0, 1)
      end

      if context.readOnly ~= true and not state.flat and state.remaining <= 0 then
        state.flat = true
        beamstate.deflateTire(index)
      elseif context.readOnly ~= true and not state.flat and state.remaining < 0.10 and load > 0 and
          abrasionSlipSeverity > 0.2 then
        local riskPerSecond = ((0.10 - state.remaining) / 0.10) *
                                tireModel.clamp(abrasionSlipSeverity, 0, 5) * 0.015
        if math.random() < riskPerSecond * dt then
          state.flat = true
          beamstate.deflateTire(index)
        end
      end

      conditionGrip = tireModel.gripMultiplier(
        state.remaining, averageTemperature(state), state.workingTemperature)
    else
      -- Keep the existing array so disabled maintenance does not allocate one
      -- replacement table per wheel on every rendered frame.
      for ring = 1, 4 do
        state.temperature[ring] = context.ambientTemperature
      end
    end
    local appliedGrip = conditionGrip * weatherGrip
    setWheelGrip(index, appliedGrip)
    gripApplied = true

    if not wasFlat and state.flat then reportTimer = REPORT_INTERVAL end

    if stream then
      table.insert(stream.data, {
        name = state.name,
        working_temp = state.workingTemperature,
        temp = deepCopy(state.temperature),
        avg_temp = averageTemperature(state),
        condition = state.remaining * 100,
        tyreGrip = appliedGrip,
        conditionGrip = conditionGrip,
        weatherGrip = weatherGrip,
        roadWetness = weatherWetness,
        compound = compound,
        camber = 0,
        contact_material = groundName,
        flat = state.flat,
      })
    end
  end
  if not context.enabled and beamstate then
    beamstate.lowpressure = false
    for _, wheel in pairs(wheels.wheels or {}) do
      if wheel.isTireDeflated == true or wheel.isBroken == true then
        beamstate.lowpressure = true
        break
      end
    end
  end
  if stream then
    sendTelemetry(stream)
  end
end

local function reportState(force)
  if not configured then return end
  local info = providerInfo()
  local providerKey = table.concat({tostring(info.id), tostring(info.version), tostring(info.apiVersion)}, ":")
  if selectedProvider ~= "bundled" then
    sendTelemetry({data = {}, provider = info, enabled = context.enabled == true})
  end
  if selectedProvider == "external" then
    local api = externalApi(externalExtension())
    local ok, state = false, nil
    if api then ok, state = pcall(api.getState) end
    local payload = type(state) == "table" and deepCopy(state) or {}
    payload.provider = info
    payload.wheels = payload.wheels or {}
    obj:queueGameEngineLua("if career_modules_tireSystem then career_modules_tireSystem.receiveVehicleState(" ..
      tostring(obj:getID()) .. "," .. serialize(payload) .. ") end")
    lastProviderKey = providerKey
    return
  end

  local payload = {provider = info, wheels = {}}
  if selectedProvider == "bundled" then
    for index, state in pairs(wheelStates) do
      local cached = wheelCache[index] or {}
      table.insert(payload.wheels, {
        name = state.name,
        remaining = state.remaining,
        flat = state.flat,
        width = cached.width,
        partOrigin = cached.partOrigin,
        partPath = cached.partPath,
        containingSlot = cached.containingSlot,
      })
    end
    table.sort(payload.wheels, function(a, b) return a.name < b.name end)
  end
  if force or #payload.wheels > 0 or lastProviderKey ~= providerKey then
    obj:queueGameEngineLua("if career_modules_tireSystem then career_modules_tireSystem.receiveVehicleState(" ..
      tostring(obj:getID()) .. "," .. serialize(payload) .. ") end")
  end
  lastProviderKey = providerKey
end

function M.configure(nextContext)
  if type(nextContext) ~= "table" then return false end
  configured = true
  local wasEnabled = context.enabled == true
  local enabledChanged = wasEnabled ~= (nextContext.enabled == true)
  local inventoryChanged = configuredInventoryId ~= tonumber(nextContext.inventoryId)
  local revisionChanged = configuredStateRevision ~= tonumber(nextContext.stateRevision)
  if wasEnabled and nextContext.enabled ~= true and selectedProvider == "bundled" then
    reportState(true)
  end
  context = deepCopy(nextContext)
  context.ambientTemperature = tonumber(context.ambientTemperature) or 21
  context.initialState = type(context.initialState) == "table" and context.initialState or {}
  context.groundModels = type(context.groundModels) == "table" and context.groundModels or {}
  context.roadWetness = tireModel.clamp(context.roadWetness, 0, 1)
  context.wetGripMultipliers = type(context.wetGripMultipliers) == "table" and context.wetGripMultipliers or {}
  context.wetGroundModels = type(context.wetGroundModels) == "table" and context.wetGroundModels or {}
  configuredInventoryId = tonumber(context.inventoryId)
  configuredStateRevision = tonumber(context.stateRevision)
  if inventoryChanged or revisionChanged or enabledChanged then
    wheelStates = {}
    wheelCache = {}
  end
  local info = detectProvider(true)
  if revisionChanged and selectedProvider == "external" then
    local api = externalApi(externalExtension())
    if api and type(api.handlePartChanges) == "function" then
      pcall(api.handlePartChanges, deepCopy(context))
    end
  end
  if selectedProvider == "bundled" and context.enabled ~= true then
    resetTemperatures()
    sendTelemetry({data = {}, provider = info, enabled = false})
  end
  telemetryTimer = TELEMETRY_INTERVAL
  reportState(lastProviderKey == nil)
  return info
end

function M.getRlsTireProviderInfo()
  return providerInfo()
end

function M.getRlsTireState()
  local result = {provider = providerInfo(), wheels = {}}
  for index, state in pairs(wheelStates) do
    local cached = wheelCache[index] or {}
    table.insert(result.wheels, {
      name = state.name, remaining = state.remaining, flat = state.flat,
      partOrigin = cached.partOrigin, partPath = cached.partPath, containingSlot = cached.containingSlot,
    })
  end
  return result
end

function M.getRlsTireTelemetry()
  local result = {
    provider = providerInfo(),
    enabled = context.enabled == true,
    roadWetness = context.roadWetness,
    data = {},
  }
  for index, state in pairs(wheelStates) do
    local cached = wheelCache[index] or {}
    table.insert(result.data, {
      name = state.name,
      remaining = state.remaining,
      condition = state.remaining * 100,
      flat = state.flat,
      temperature = deepCopy(state.temperature),
      averageTemperature = averageTemperature(state),
      workingTemperature = state.workingTemperature,
      width = cached.width,
      partOrigin = cached.partOrigin,
      partPath = cached.partPath,
      compound = cached.compound or tireModel.classifyTireCompound(cached),
      weatherGrip = cached.weatherGrip or 1,
      weatherWetness = cached.weatherWetness or 0,
      contactMaterial = cached.contactMaterial,
    })
  end
  table.sort(result.data, function(a, b) return a.name < b.name end)
  return result
end

function M.resetThermalsAndGrip()
  reportState(true)
  if selectedProvider == "external" then
    local api = externalApi(externalExtension())
    if api and type(api.restore) == "function" then pcall(api.restore) end
  end
  resetTemperatures()
  restoreGrip()
end

function M.applyFreshAndInflate(nextInitial)
  if type(nextInitial) == "table" then
    context.initialState = deepCopy(nextInitial)
  else
    context.initialState = {}
  end
  if not wheels or not wheels.wheelRotators then
    resetTemperatures()
    restoreGrip()
    reportState(true)
    return true
  end
  for index, rotator in pairs(wheels.wheelRotators) do
    local _, state = cacheRotator(index, rotator)
    local saved = context.initialState[state.name]
    if saved then
      state.remaining = tireModel.clamp(tonumber(saved.remaining) or 1, 0, 1)
      state.flat = saved.flat == true
    else
      state.remaining = 1
      state.flat = false
    end
    if not state.flat then
      restoreDeflatedTire(index, rotator)
    end
  end
  resetTemperatures()
  restoreGrip()
  reportState(true)
  return true
end

function M.flushState()
  if selectedProvider == "external" then
    local api = externalApi(externalExtension())
    if api and type(api.flush) == "function" then pcall(api.flush) end
  end
  reportState(true)
  return true
end

function M.updateGFX(dt)
  dt = math.min(math.max(tonumber(dt) or 0, 0), 0.1)
  -- The GE tire system loads this extension only for managed/preview vehicles.
  -- Keep it dormant until configure() arrives so initialization cannot apply
  -- grip or wear before ownership and maintenance state are known.
  if not configured then return end
  providerCheckTimer = providerCheckTimer + dt
  reportTimer = reportTimer + dt
  telemetryTimer = telemetryTimer + dt
  waterCheckTimer = waterCheckTimer + dt
  if providerCheckTimer >= 1 then
    providerCheckTimer = 0
    detectProvider(false)
  end
  local emitTelemetry = telemetryTimer >= TELEMETRY_INTERVAL
  if emitTelemetry then telemetryTimer = 0 end
  local checkWater = waterCheckTimer >= WATER_CHECK_INTERVAL
  if checkWater then waterCheckTimer = 0 end
  if selectedProvider == "bundled" then updateBundled(dt, emitTelemetry, checkWater) end
  if reportTimer >= REPORT_INTERVAL then
    reportTimer = 0
    reportState(false)
  end
end

function M.onReset()
  reportState(true)
  vehicleMass = getVehicleMass()
  resetTemperatures()
  restoreGrip()
  obj:queueGameEngineLua("if career_modules_tireSystem then career_modules_tireSystem.sendContextForVehicle(" ..
    tostring(obj:getID()) .. ",true) end")
end

function M.onInit()
  vehicleMass = getVehicleMass()
  detectProvider(true)
  obj:queueGameEngineLua("if career_modules_tireSystem then career_modules_tireSystem.sendContextForVehicle(" ..
    tostring(obj:getID()) .. ",true) end")
end

function M.onVehicleSpawned()
  M.onInit()
end

return M
