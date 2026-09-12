-- Pure tire-model helpers shared by GE, vehicle Lua, and standalone tests.
local M = {}

local min = math.min
local max = math.max

local DEFAULT_WET_GRIP_MULTIPLIERS = {
  standard = 1.00,
  sport = 0.94,
  race = 0.80,
  drag = 0.72,
}

local WET_CAPABLE_IDENTIFIERS = {
  "standard", "touring", "allseason", "all_season", "eco", "rally", "offroad",
  "off_road", "allterrain", "all_terrain", "winter", "snow", "mud",
}

local DEFAULT_SURFACE_TUNING = {
  thermalMultiplier = 1,
  abrasionMultiplier = 1,
}

local SURFACE_TUNING = {
  dirt = {
    thermalMultiplier = 0.55,
    abrasionMultiplier = 0.50,
    thermalSlipCap = 3.00,
    abrasionSlipCap = 2.50,
  },
  looseDirt = {
    thermalMultiplier = 0.40,
    abrasionMultiplier = 0.35,
    thermalSlipCap = 2.50,
    abrasionSlipCap = 2.00,
  },
  sand = {
    thermalMultiplier = 0.30,
    abrasionMultiplier = 0.25,
    thermalSlipCap = 1.75,
    abrasionSlipCap = 1.25,
  },
  mud = {
    thermalMultiplier = 0.10,
    abrasionMultiplier = 0.08,
    thermalSlipCap = 1.25,
    abrasionSlipCap = 0.75,
  },
}

local function containsAny(value, identifiers)
  for _, identifier in ipairs(identifiers) do
    local token = "_" .. string.lower(tostring(identifier)):gsub("[^%w]+", "_") .. "_"
    if string.find(value, token, 1, true) then return true end
  end
  return false
end

local function clamp(value, lower, upper)
  return min(max(tonumber(value) or 0, lower), upper)
end

function M.clamp(value, lower, upper)
  return clamp(value, lower, upper)
end

function M.remainingFromMiles(miles)
  return clamp(1 - 0.9 * max(tonumber(miles) or 0, 0) / 300000, 0.10, 1)
end

function M.widthWearMultiplier(widthMeters)
  local effectiveWidth = max(tonumber(widthMeters) or 0.205, 0.150)
  return clamp(0.205 / effectiveWidth, 0.75, 1.25)
end

function M.temperatureWearMultiplier(temperatureC, workingTemperatureC)
  local working = max(tonumber(workingTemperatureC) or 85, 1)
  local overheat = max((tonumber(temperatureC) or working) - working, 0) / working
  return 1 + clamp(overheat ^ 1.35 * 8, 0, 5)
end

function M.overheatGripWearMultiplier(inherentGrip, temperatureC, workingTemperatureC)
  local working = max(tonumber(workingTemperatureC) or 85, 1)
  local overheat = clamp(((tonumber(temperatureC) or working) - working) / working, 0, 1)
  local normalizedGrip = clamp(((tonumber(inherentGrip) or 1) - 1) / 0.30, 0, 1)
  return 1 + normalizedGrip * overheat * 0.10
end

function M.waterCoolingMultiplier(inWater)
  -- BeamNG's brake thermals use 1 + a default underwater coefficient of 20.
  return inWater == true and 21 or 1
end

function M.wheelTouchesWater(rotator, vehicleObject)
  if type(rotator) ~= "table" or vehicleObject == nil then return false end

  -- Fast path 1: The current road-contact node sits at the bottom of the tire where water
  -- is encountered first. If it is in water, the tire is touching water.
  if rotator.lastTreadContactNode ~= nil and vehicleObject:inWater(rotator.lastTreadContactNode) then
    return true
  end

  -- Fast path 2: Check axle/center nodes. If the axle is in water, the wheel is submerged.
  if (rotator.node1 ~= nil and vehicleObject:inWater(rotator.node1)) or
     (rotator.node2 ~= nil and vehicleObject:inWater(rotator.node2)) then
    return true
  end

  -- Fast path 3: If the wheel has an active road contact node and neither the contact
  -- nor the axle is in water, the tire is on dry ground; skip scanning dozens of tread nodes.
  if rotator.lastTreadContactNode ~= nil then
    return false
  end

  -- Fallback for airborne or floating wheels without active ground contact: scan tread nodes.
  for _, nodeId in ipairs(rotator.treadNodes or {}) do
    if vehicleObject:inWater(nodeId) then return true end
  end
  for _, nodeId in ipairs(rotator.nodes or {}) do
    if vehicleObject:inWater(nodeId) then return true end
  end

  return false
end

function M.temperatureWithAmbientFloor(temperatureC, ambientTemperatureC)
  local ambient = tonumber(ambientTemperatureC) or 21
  return max(tonumber(temperatureC) or ambient, ambient)
end

function M.slipSeverities(longitudinalSlip, lateralSlip)
  local longitudinal = math.abs(tonumber(longitudinalSlip) or 0)
  local lateral = math.abs(tonumber(lateralSlip) or 0)

  -- Mild slip still makes heat, but only obvious wheelspin or a sustained slide
  -- contributes direct abrasion. This keeps normal understeer out of the wear
  -- term while burnouts and drifting quickly move beyond the abuse dead zones.
  local thermal = max(longitudinal - 0.15, 0) + max(lateral - 0.05, 0) * 0.20
  local abrasion = max(longitudinal - 1.00, 0) + max(lateral - 1.50, 0) * 0.12
  return thermal, abrasion
end

function M.surfaceTireTuning(groundName)
  local name = string.upper(tostring(groundName or ""))

  -- Test the most yielding surfaces first because names such as DIRT_SANDY
  -- also contain the broader DIRT token.
  if string.find(name, "MUD", 1, true) then return SURFACE_TUNING.mud end
  if string.find(name, "SAND", 1, true) then return SURFACE_TUNING.sand end
  if string.find(name, "DIRT", 1, true) and string.find(name, "LOOSE", 1, true) then
    return SURFACE_TUNING.looseDirt
  end
  if string.find(name, "DIRT", 1, true) or string.find(name, "GRAVEL", 1, true) then
    return SURFACE_TUNING.dirt
  end
  return DEFAULT_SURFACE_TUNING
end

function M.smoothSlipCap(severity, cap)
  local value = max(tonumber(severity) or 0, 0)
  local limit = tonumber(cap)
  if not limit or limit <= 0 then return value end

  -- Approaches the cap smoothly while remaining effectively linear for normal
  -- slip. This prevents loose-ground wheel-speed spikes from dominating heat.
  return value / math.sqrt(1 + (value / limit) ^ 2)
end

function M.combineWearComponents(distanceWear, slipWear, loadMultiplier)
  -- Slip wear already contains the wheel load through abrasion work. Apply the
  -- extra load multiplier only to rolling-distance wear so axle load is not
  -- counted twice during wheelspin or a slide.
  return max(tonumber(distanceWear) or 0, 0) * max(tonumber(loadMultiplier) or 0, 0) +
         max(tonumber(slipWear) or 0, 0)
end

function M.gripMultiplier(remaining, temperatureC, workingTemperatureC)
  local tread = clamp(remaining, 0, 1)
  local working = max(tonumber(workingTemperatureC) or 85, 1)
  local distance = math.abs((tonumber(temperatureC) or working) - working)
  local temperatureGrip = 1.01 - clamp((distance / 130) ^ 1.3 * 0.12, 0, 0.18)
  local wearGrip = 0.75 + 0.25 * math.sqrt(tread)
  return clamp(temperatureGrip * wearGrip, 0.60, 1.02)
end

function M.classifyTireCompound(tire)
  tire = type(tire) == "table" and tire or {}
  local identity = "_" .. string.lower(table.concat({
    tostring(tire.partOrigin or ""),
    tostring(tire.partPath or ""),
  }, " ")):gsub("[^%w]+", "_") .. "_"

  -- Explicit wet-capable families win over broad performance words that may
  -- occur elsewhere in a custom part path.
  if containsAny(identity, WET_CAPABLE_IDENTIFIERS) then return "standard" end
  if containsAny(identity, {"drag"}) then return "drag" end
  if containsAny(identity, {"slick", "semislick", "semi_slick", "race", "racing", "competition"}) then
    return "race"
  end
  if containsAny(identity, {"sport", "performance", "highperformance", "high_performance"}) then
    return "sport"
  end

  local staticFriction = tonumber(tire.baseFriction or tire.frictionCoef) or 1
  local slidingFriction = tonumber(tire.slidingFriction or tire.slidingFrictionCoef) or staticFriction
  local averageFriction = (staticFriction + slidingFriction) * 0.5
  if averageFriction >= 1.20 then return "drag" end

  local treadCoef = tonumber(tire.treadCoef)
  if treadCoef and treadCoef <= 0.15 then return "race" end
  return "standard"
end

function M.wetGripMultiplier(wetness, tire, configuredMultipliers)
  local compound = M.classifyTireCompound(tire)
  local configured = type(configuredMultipliers) == "table" and configuredMultipliers or {}
  local fullWetMultiplier = tonumber(configured[compound]) or DEFAULT_WET_GRIP_MULTIPLIERS[compound] or 1
  fullWetMultiplier = clamp(fullWetMultiplier, 0.10, 1)
  local normalizedWetness = clamp(wetness, 0, 1)
  return 1 + (fullWetMultiplier - 1) * normalizedWetness, compound
end

function M.wetnessForSurface(wetness, groundName, wetGroundModels)
  if type(wetGroundModels) ~= "table" or wetGroundModels[tostring(groundName or "")] ~= true then
    return 0
  end
  return clamp(wetness, 0, 1)
end

function M.average(values, fallback)
  local total, count = 0, 0
  for _, value in pairs(values or {}) do
    if tonumber(value) then
      total = total + tonumber(value)
      count = count + 1
    end
  end
  return count > 0 and total / count or fallback
end

function M.selectProvider(externalPresent, apiCompatible)
  if externalPresent then
    return apiCompatible and "external" or "legacy"
  end
  return "bundled"
end

return M
