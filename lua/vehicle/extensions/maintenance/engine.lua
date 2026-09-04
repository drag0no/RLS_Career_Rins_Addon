local M = {}

local common = require('vehicle/extensions/maintenance/common')

local abs = math.abs
local max = math.max
local min = math.min

local symptomDurations = {
  roughRunning = {6, 14},
  ticking = {5, 11},
  roughIdle = {5, 12},
  torqueDip = {1.5, 4},
  powerFade = {3, 7},
  stall = {0.5, 1.5}
}

local minimumHardFailureMileage = 190000
local maintenanceIntervals = {
  oilCondition = {fresh = 150, aged = 120, worn = 90},
  oilLevel = {fresh = 240, aged = 180, worn = 120},
  ignitionService = {fresh = 280, aged = 220, worn = 140}
}
local serviceTargetValues = {
  oilCondition = 0.55,
  oilLevel = 0.5,
  ignitionService = 0.6
}
local pistonRingOilLossPerSecond = {
  fresh = 0.000024,
  aged = 0.000036,
  worn = 0.000054
}
local moderateDriveReference = {
  rpmFactor = 0.3,
  loadFactor = 0.35,
  heatFactor = 0.15,
  outputStressFactor = 0,
  limitStressFactor = 0
}

local function getDefaultMaintenance()
  return {
    oilCondition = 1,
    oilLevel = 1,
    ignitionService = 1
  }
end

local function getLimitStressFactor(env)
  env = env or {}
  local rpmNearLimit = common.clamp(common.linearScale(env.rpmFactor or 0, 0.72, 1, 0, 1), 0, 1)
  local loadNearLimit = common.clamp(common.linearScale(env.loadFactor or 0, 0.78, 1, 0, 1), 0, 1)
  local heatNearLimit = common.clamp(common.linearScale(env.heatFactor or 0, 0.7, 1, 0, 1), 0, 1)
  local overheatFactor = common.clamp(env.overheatFactor or 0, 0, 1)

  return common.clamp(rpmNearLimit * 0.95 + loadNearLimit * 1.1 + heatNearLimit * 0.75 + overheatFactor * 1.45, 0, 2.2)
end

local function reshapeOutputStressFactor(outputStressFactor)
  return common.sampleCurve(max(tonumber(outputStressFactor) or 0, 0), {
    {0, 0},
    {0.15, 0.02},
    {0.35, 0.10},
    {0.8, 0.45},
    {1.6, 1.2},
    {3.0, 2.5},
    {5.0, 4.0}
  })
end

local function reshapeLimitStressFactor(limitStressFactor)
  return common.sampleCurve(max(tonumber(limitStressFactor) or 0, 0), {
    {0, 0},
    {0.4, 0.05},
    {0.9, 0.28},
    {1.4, 0.65},
    {2.2, 1.25}
  })
end

local function getLiveTorqueHoldCoef(torqueHoldCoef, loadFactor, rpmCapacity)
  local baseHoldCoef = common.clamp(tonumber(torqueHoldCoef) or 1, 0, 1)
  local baseLoss = 1 - baseHoldCoef
  if baseLoss <= 0 then
    return 1
  end

  local loadRampFactor = common.sampleCurve(common.clamp(tonumber(loadFactor) or 0, 0, 1), {
    {0.00, 0.00},
    {0.35, 0.00},
    {0.55, 0.18},
    {0.75, 0.55},
    {0.90, 0.88},
    {1.00, 1.00}
  })
  local rpmRampFactor = common.sampleCurve(common.clamp(tonumber(rpmCapacity) or 0, 0, 1.1), {
    {0.00, 0.00},
    {0.55, 0.00},
    {0.78, 0.20},
    {0.92, 0.50},
    {1.00, 0.70},
    {1.10, 0.70}
  })
  local combinedRampFactor = common.clamp(loadRampFactor * 0.8 + rpmRampFactor * 0.2, 0, 1)

  return common.clamp(1 - baseLoss * combinedRampFactor, baseHoldCoef, 1)
end

local function getPowerLimitReason(derived, symptom, directDriveSeverity, powerCapActive, lubricationDamageStage)
  if symptom == 'stall' or symptom == 'powerFade' or symptom == 'torqueDip' then
    return 'Temporary symptom'
  end
  if directDriveSeverity >= 0.35 or (derived.oilStarvationSeverity or 0) >= 0.2 or (lubricationDamageStage or 0) >= 0.35 then
    return 'Oil starvation'
  end
  if (derived.ignitionSeverity or 0) >= 0.45 then
    return 'Severe ignition issue'
  end
  return 'Maintenance torque protection'
end

local function getDriveMultiplierValues(rpmFactor, loadFactor, heatFactor, outputStressFactor, limitStressFactor)
  return {
    oilCondition = 1 + rpmFactor * 0.55 + loadFactor * 0.85 + heatFactor * 0.15 + outputStressFactor * 0.75 + limitStressFactor * 0.45,
    oilLevel = 1 + rpmFactor * 1.25 + loadFactor * 0.35 + heatFactor * 0.10 + outputStressFactor * 0.12 + limitStressFactor * 0.15,
    ignitionService = 1 + rpmFactor * 0.35 + loadFactor * 1.00 + heatFactor * 0.15 + outputStressFactor * 1.20 + limitStressFactor * 0.50
  }
end

local function getDriveMultipliers(env)
  env = env or {}
  local limitStressFactor = reshapeLimitStressFactor(getLimitStressFactor(env))
  local loadGate = common.sampleCurve(common.clamp(env.loadFactor or 0, 0, 1), {
    {0, 0},
    {0.35, 0},
    {0.65, 0.25},
    {0.85, 0.7},
    {1, 1}
  })
  local outputStressFactor = reshapeOutputStressFactor(max(tonumber(env.outputStressFactor) or tonumber(env.powerFactor) or 0, 0)) * loadGate
  local rawMultipliers = getDriveMultiplierValues(
    common.clamp(env.rpmFactor or 0, 0, 1),
    common.clamp(env.loadFactor or 0, 0, 1),
    common.clamp(env.heatFactor or 0, 0, 1),
    outputStressFactor,
    limitStressFactor
  )
  local referenceMultipliers = getDriveMultiplierValues(
    moderateDriveReference.rpmFactor,
    moderateDriveReference.loadFactor,
    moderateDriveReference.heatFactor,
    moderateDriveReference.outputStressFactor,
    moderateDriveReference.limitStressFactor
  )

  return {
    raw = rawMultipliers,
    normalized = {
      oilCondition = common.normalizeDriveMultiplier(rawMultipliers.oilCondition, referenceMultipliers.oilCondition),
      oilLevel = common.normalizeDriveMultiplier(rawMultipliers.oilLevel, referenceMultipliers.oilLevel),
      ignitionService = common.normalizeDriveMultiplier(rawMultipliers.ignitionService, referenceMultipliers.ignitionService)
    }
  }
end

local function getAggressiveDriveSeverity(env)
  env = env or {}
  local limitStressFactor = reshapeLimitStressFactor(getLimitStressFactor(env))
  local outputStressFactor = reshapeOutputStressFactor(max(tonumber(env.outputStressFactor) or tonumber(env.powerFactor) or 0, 0))
  local stressBlend = common.clamp(
    common.clamp(env.rpmFactor or 0, 0, 1) * 0.32 +
        common.clamp(env.loadFactor or 0, 0, 1) * 0.30 +
        common.clamp(env.heatFactor or 0, 0, 1) * 0.14 +
        common.clamp(limitStressFactor, 0, 1.25) * 0.14 +
        common.clamp(outputStressFactor, 0, 1.6) * 0.10,
    0,
    1.3
  )

  return common.sampleCurve(stressBlend, {
    {0.00, 0.00},
    {0.35, 0.00},
    {0.55, 0.18},
    {0.72, 0.46},
    {0.90, 0.88},
    {1.10, 1.32},
    {1.30, 1.70}
  })
end

local function getOilConditionStressMultiplier(env)
  return 1
end

local function getMileageOilLevelMultiplier(avgMiles)
  return common.getLevelMileageMultiplier('oilLevel', avgMiles)
end

local function getEffectiveDrainMultipliers(env, avgMiles)
  local driveMultipliers = getDriveMultipliers(env)
  local oilConditionStressMultiplier = getOilConditionStressMultiplier(env)
  local oilLevelMileageMultiplier = getMileageOilLevelMultiplier(avgMiles)

  return {
    raw = {
      oilCondition = driveMultipliers.raw.oilCondition * oilConditionStressMultiplier,
      oilLevel = driveMultipliers.raw.oilLevel,
      ignitionService = driveMultipliers.raw.ignitionService
    },
    normalized = {
      oilCondition = driveMultipliers.normalized.oilCondition * oilConditionStressMultiplier,
      oilLevel = driveMultipliers.normalized.oilLevel,
      ignitionService = driveMultipliers.normalized.ignitionService
    },
    oilConditionStressMultiplier = oilConditionStressMultiplier,
    oilLevelMileageMultiplier = oilLevelMileageMultiplier
  }
end

local function getExtremePowerMultiplier(powerHp)
  return common.sampleCurve(max(tonumber(powerHp) or 0, 0), {
    {0, 1},
    {700, 1},
    {1000, 31},
    {2500, 55},
    {5000, 88}
  })
end

local function getExtremeOutputGate(env)
  env = env or {}
  local loadGate = common.sampleCurve(common.clamp(env.loadFactor or 0, 0, 1), {
    {0, 0},
    {0.65, 0},
    {0.80, 0.25},
    {0.90, 0.65},
    {0.95, 1},
    {1, 1}
  })
  local rpmParticipation = 0.35 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.65
  return loadGate * rpmParticipation
end

local function getWearBandRate(rateTable, avgMiles)
  local wear = common.getWearProfile(avgMiles)
  return tonumber(rateTable[wear.bandName]) or 0
end

local function drainMaintenance(maintenance, deltaMiles, avgMiles, env)
  maintenance = common.shallowCopy(maintenance)
  env = env or {}
  local effectiveDrainMultipliers = getEffectiveDrainMultipliers(env, avgMiles)
  local driveMultipliers = effectiveDrainMultipliers.normalized
  local profile = type(env.profile) == 'table' and env.profile or {}
  local classIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile)
  local dieselIntervalMultiplier = profile.fuelType == 'diesel' and 1.25 or 1
  local dieselLoadMultiplier = profile.fuelType == 'diesel' and (1 + common.clamp(env.loadFactor or 0, 0, 1) * 0.25) or 1
  local dieselOilLevelMultiplier = profile.fuelType == 'diesel' and 0.85 or 1
  local torqueCapacityStress = common.getTorqueCapacityStress(env.combustionTorque, env.maxTorqueRating)
  local oilLevelCapacityFactor = common.getCapacityFactor('oil', profile)
  local oilLevelMileageMultiplier = getMileageOilLevelMultiplier(avgMiles)
  local oilLevelTorqueMultiplier = 1 + torqueCapacityStress * 1.5
  local oilConditionTorqueMultiplier = 1 + torqueCapacityStress * 4
  local oilTempMultiplier = common.getOilTemperatureMultiplier(env.oilTemp)
  local lowOilConditionMultiplier = common.getLowFluidConditionMultiplier(maintenance.oilLevel or 1)
  local oilConditionInterval = maintenanceIntervals.oilCondition.fresh * classIntervalMultiplier * dieselIntervalMultiplier
  local oilLevelInterval = maintenanceIntervals.oilLevel.fresh
  local ignitionInterval = maintenanceIntervals.ignitionService.fresh

  local extremeOutputGate = getExtremeOutputGate(env)
  local engineRuntimeMiles = max(tonumber(env.engineRunningSeconds) or 0, 0) / 60
  local normalOilEquivalentMiles = deltaMiles * driveMultipliers.oilLevel * oilLevelMileageMultiplier * oilLevelTorqueMultiplier *
                                     dieselOilLevelMultiplier
  local extremeEquivalentMiles = max(deltaMiles, engineRuntimeMiles) * extremeOutputGate *
                                   max(getExtremePowerMultiplier(env.powerHp) - 1, 0)
  local oilLevelEquivalentMiles = (normalOilEquivalentMiles + extremeEquivalentMiles) * oilLevelCapacityFactor
  local stationaryConditionGate = max(extremeOutputGate, torqueCapacityStress,
    common.clamp((oilTempMultiplier - 1) / 7, 0, 1))
  local oilConditionEquivalentMiles = max(deltaMiles, engineRuntimeMiles * stationaryConditionGate)

  maintenance.oilCondition = common.applyIntervalWear(
    maintenance.oilCondition or 1,
    oilConditionInterval,
    oilConditionEquivalentMiles,
    driveMultipliers.oilCondition * oilTempMultiplier * lowOilConditionMultiplier * oilConditionTorqueMultiplier * dieselLoadMultiplier,
    serviceTargetValues.oilCondition
  )
  maintenance.oilLevel = common.applyIntervalWear(
    maintenance.oilLevel or 1,
    oilLevelInterval,
    oilLevelEquivalentMiles,
    1,
    serviceTargetValues.oilLevel
  )
  maintenance.ignitionService = common.applyIntervalWear(
    maintenance.ignitionService or 1,
    ignitionInterval,
    deltaMiles,
    driveMultipliers.ignitionService,
    serviceTargetValues.ignitionService
  )

  if profile.fuelType == 'diesel' then
    local idleRuntimeSeconds = max(tonumber(env.idleRuntimeSeconds) or 0, 0)
    if idleRuntimeSeconds > 0 then
      maintenance.oilCondition = common.applyIntervalWear(
        maintenance.oilCondition or 1,
        oilConditionInterval,
        idleRuntimeSeconds * (25 / 3600),
        lowOilConditionMultiplier,
        serviceTargetValues.oilCondition
      )
    end
  end

  if env.pistonRingsDamaged == true then
    local engineRunningSeconds = max(tonumber(env.engineRunningSeconds) or 0, 0)
    if engineRunningSeconds > 0 then
      local rpmCapacity = common.clamp(tonumber(env.rpmCapacity) or tonumber(env.rpmFactor) or 0, 0, 1.35)
      local rpmOilLossFactor = 0.35 + rpmCapacity * 1.7 + max(rpmCapacity - 0.82, 0) * 2.8
      local heatOilLossFactor = 1 + common.clamp(env.heatFactor or 0, 0, 1) * 0.45 + common.clamp(env.overheatFactor or 0, 0, 1) * 0.8
      local ringOilLoss = pistonRingOilLossPerSecond.fresh * engineRunningSeconds * rpmOilLossFactor *
                              heatOilLossFactor * oilLevelMileageMultiplier * oilLevelCapacityFactor
      maintenance.oilLevel = common.clamp((maintenance.oilLevel or 1) - ringOilLoss, 0, 1)
    end
  end

  return maintenance
end

local function resetEngineState(engine, base, derived)
  if engine.wearFrictionCoef ~= nil then
    engine.wearFrictionCoef = derived and derived.ageWearFrictionCoef or 1
  end
  if engine.wearDynamicFrictionCoef ~= nil then
    engine.wearDynamicFrictionCoef = derived and derived.ageWearDynamicFrictionCoef or 1
  end
  if engine.wearIdleAVReadErrorRangeCoef ~= nil then
    engine.wearIdleAVReadErrorRangeCoef = derived and derived.ageWearIdleErrorCoef or 1
  end
  if engine.damageFrictionCoef ~= nil then
    engine.damageFrictionCoef = base.damageFrictionCoef or 1
  end
  if engine.damageDynamicFrictionCoef ~= nil then
    engine.damageDynamicFrictionCoef = base.damageDynamicFrictionCoef or 1
  end
  if engine.damageIdleAVReadErrorRangeCoef ~= nil then
    engine.damageIdleAVReadErrorRangeCoef = base.damageIdleAVReadErrorRangeCoef or 1
  end
  if engine.fastIgnitionErrorChance ~= nil then
    engine.fastIgnitionErrorChance = base.fastIgnitionErrorChance or 0
  end
  if engine.slowIgnitionErrorChance ~= nil then
    engine.slowIgnitionErrorChance = base.slowIgnitionErrorChance or 0
  end
  if base.friction ~= nil then
    engine.friction = base.friction
  end
  if base.dynamicFriction ~= nil then
    engine.dynamicFriction = base.dynamicFriction
  end
  if base.originalMaxTorqueLimit ~= nil then
    engine.maxTorqueLimit = base.originalMaxTorqueLimit
  end
  if base.idleAVReadErrorRangeHalf ~= nil then
    engine.idleAVReadErrorRangeHalf = base.idleAVReadErrorRangeHalf
  end
  if base.idleAVReadErrorRange ~= nil then
    engine.idleAVReadErrorRange = base.idleAVReadErrorRange
  end
end

local function buildDerived(state, env)
  local wear = common.getWearProfile(env.avgMiles)
  local maintenanceAvg = common.getAverageMaintenance(state.maintenance)
  local maintenancePenalty = 1 - maintenanceAvg
  local neglectSeverity = common.getMaintenanceSeverity(maintenanceAvg)
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local rpmFactor = common.clamp(env.rpmFactor or 0, 0, 1)
  local heatFactor = common.clamp(env.heatFactor or 0, 0, 1)
  local profile = type(env.profile) == 'table' and env.profile or {}
  local effectiveDrainMultipliers = getEffectiveDrainMultipliers(env, env.avgMiles)
  local driveMultipliers = {
    raw = effectiveDrainMultipliers.raw,
    normalized = effectiveDrainMultipliers.normalized
  }
  local limitStressFactor = getLimitStressFactor(env)
  local torqueCapacityStress, torqueCapacityRatio = common.getTorqueCapacityStress(env.combustionTorque, env.maxTorqueRating)
  local oilTemperatureMultiplier = common.getOilTemperatureMultiplier(env.oilTemp)
  local oilLevelMileageMultiplier = common.getLevelMileageMultiplier('oilLevel', env.avgMiles)
  local oilCapacityFactor = common.getCapacityFactor('oil', profile)
  local classConditionIntervalMultiplier = common.getClassConditionIntervalMultiplier(profile)
  local dieselIntervalMultiplier = profile.fuelType == 'diesel' and 1.25 or 1
  local dieselLoadMultiplier = profile.fuelType == 'diesel' and (1 + loadFactor * 0.25) or 1
  local dieselOilLevelMultiplier = profile.fuelType == 'diesel' and 0.85 or 1
  local pistonRingsDamaged = env.pistonRingsDamaged == true
  local pistonRingOilConsumptionRate = 0
  local oilCondition = common.clamp(state.maintenance.oilCondition or 1, 0, 1)
  local oilLevel = common.clamp(state.maintenance.oilLevel or 1, 0, 1)
  local ignitionService = common.clamp(state.maintenance.ignitionService or 1, 0, 1)
  local lowOilConditionMultiplier = common.getLowFluidConditionMultiplier(oilLevel)
  local integrityValue = common.clamp(env.integrityValue or 1, 0, 1)
  local oilTemp = max(tonumber(env.oilTemp) or 0, 0)
  local oilHeatFactor = common.clamp(env.oilHeatFactor or 0, 0, 1)
  local oilOverheatFactor = common.clamp(env.oilOverheatFactor or 0, 0, 1)
  local oilLevelDriveSeverity = common.sampleCurve(oilLevel, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.30, 0.24},
    {0.16, 0.58},
    {0.08, 0.98},
    {0.0, 1.3}
  })
  local oilStarvationSeverity = common.sampleCurve(oilLevel, {
    {1.0, 0},
    {0.20, 0},
    {0.10, 0.2},
    {0.05, 0.55},
    {0.02, 1.0},
    {0.0, 1.35}
  })
  local oilConditionSeverity = common.sampleCurve(oilCondition, {
    {1.0, 0},
    {0.18, 0},
    {0.08, 0.18},
    {0.03, 0.42},
    {0.0, 0.75}
  })
  local oilConditionDriveSeverity = common.sampleCurve(oilCondition, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.30, 0.24},
    {0.16, 0.52},
    {0.05, 0.84},
    {0.0, 1.05}
  })
  local ignitionSeverity = common.sampleCurve(ignitionService, {
    {1.0, 0},
    {0.70, 0},
    {0.50, 0.06},
    {0.30, 0.24},
    {0.16, 0.56},
    {0.05, 0.90},
    {0.0, 1.15}
  })
  local integritySeverity = common.sampleCurve(integrityValue, {
    {1.0, 0},
    {0.82, 0},
    {0.65, 0.15},
    {0.45, 0.38},
    {0.25, 0.72},
    {0.10, 1.05},
    {0.0, 1.3}
  })
  local severeOilStarvation = oilLevel <= 0.05 and oilCondition <= 0.14
  local catastrophicOilStarvation = oilLevel <= 0.015 and oilCondition <= 0.05
  local dryOilLockup = oilLevel <= 0.001
  local lubricationThermalSeverity = common.clamp(
    oilHeatFactor * 0.18 + oilOverheatFactor * 0.42 + oilStarvationSeverity * 0.52 + oilConditionSeverity * 0.28 +
        loadFactor * 0.10 + rpmFactor * 0.08 + common.clamp(limitStressFactor, 0, 1.4) * 0.05,
    0,
    1.45
  )
  local lubricationCollapseSeverity = common.clamp(
    max(lubricationThermalSeverity * 0.9, oilStarvationSeverity * 0.95 + oilConditionSeverity * 0.55 + integritySeverity * 0.22),
    0,
    1.6
  )
  local lubricationDriveSeverity = common.clamp(
    oilLevelDriveSeverity * 0.74 + oilConditionDriveSeverity * 0.52 + integritySeverity * 0.32 +
        max(oilLevelDriveSeverity - 0.08, 0) * loadFactor * 0.34 + max(oilLevelDriveSeverity - 0.08, 0) * rpmFactor * 0.18 +
        max(oilConditionDriveSeverity - 0.1, 0) * loadFactor * 0.14 + common.clamp(limitStressFactor, 0, 1.4) * 0.08,
    0,
    1.85
  )
  local criticalOilFailureSeverity = common.clamp(
    max(
      lubricationCollapseSeverity * 0.94,
      oilStarvationSeverity * 1.05 + oilConditionSeverity * 0.82 + lubricationThermalSeverity * 0.52 +
          max(oilStarvationSeverity - 0.52, 0) * 0.62 + max(oilConditionSeverity - 0.28, 0) * 0.46
    ),
    0,
    2.25
  )
  local cylinderWallThreatSeverity = common.clamp(
    max(
      criticalOilFailureSeverity * 0.88,
      oilStarvationSeverity * 1.28 + oilConditionSeverity * 0.95 + oilOverheatFactor * 0.40 + oilHeatFactor * 0.24 +
          max(oilStarvationSeverity - 0.70, 0) * 1.05 + max(oilConditionSeverity - 0.36, 0) * 0.70
    ) + (catastrophicOilStarvation and 0.35 or 0) + (dryOilLockup and 0.55 or 0),
    0,
    2.8
  )

  local maintenanceTorqueLimitLoss = common.sampleCurve(maintenancePenalty, {
    {0, 0},
    {0.35, 0},
    {0.6, 0.02},
    {0.8, 0.06},
    {1.0, 0.12}
  })
  local ageWearSeverity = common.sampleCurve(env.avgMiles, {
    {0, 0},
    {18600, 0},
    {100000, 0.20},
    {200000, 0.55},
    {300000, 1.0},
    {400000, 1.25}
  })
  local ageWearFrictionCoef = 1 + ageWearSeverity * 0.08
  local ageWearDynamicFrictionCoef = 1 + ageWearSeverity * 0.35
  local ageWearIdleErrorCoef = 1 + ageWearSeverity * 5
  local torqueHoldBest = 1
  local powerHoldBest = 1
  local ageTorqueLoss = 0
  local agePowerLoss = 0
  local lubricationTorqueLoss = oilLevelDriveSeverity * 0.34 + oilConditionDriveSeverity * 0.22 + lubricationDriveSeverity * 0.12 +
                                    lubricationThermalSeverity * 0.08
  local integrityTorqueLoss = integritySeverity * (0.12 + loadFactor * 0.14 + rpmFactor * 0.05)
  local stressSensitiveTorqueLoss = common.clamp(
    (oilLevelDriveSeverity * 0.34 + oilConditionDriveSeverity * 0.18 + integritySeverity * 0.24) *
        (0.18 + loadFactor * 0.48 + rpmFactor * 0.22 + common.clamp(limitStressFactor, 0, 1.4) * 0.20),
    0,
    0.68
  )
  local torqueHoldCoef = common.clamp(
    torqueHoldBest - ageTorqueLoss * maintenanceTorqueLimitLoss * 1.15 - maintenanceTorqueLimitLoss * 0.15 -
        lubricationTorqueLoss - integrityTorqueLoss - stressSensitiveTorqueLoss,
    catastrophicOilStarvation and 0.02 or (severeOilStarvation and 0.05 or 0.08),
    1
  )
  local powerHoldCoef = common.clamp(
    powerHoldBest - agePowerLoss * maintenanceTorqueLimitLoss * 0.6 - oilLevelDriveSeverity * 0.08 -
        oilConditionDriveSeverity * 0.05 - integritySeverity * 0.05 - lubricationDriveSeverity * 0.04 -
        lubricationThermalSeverity * 0.03,
    catastrophicOilStarvation and 0.35 or 0.72,
    1
  )
  local frictionCoef = 1 + (1 - torqueHoldCoef) * 0.18 + maintenancePenalty * 0.008 + oilStarvationSeverity * 0.26 +
                           oilConditionSeverity * 0.08 + integritySeverity * 0.05 + lubricationThermalSeverity * 0.10 +
                           ignitionSeverity * 0.06
  local dynamicFrictionCoef = 1 + (1 - powerHoldCoef) * 0.22 + maintenancePenalty * 0.012 + oilStarvationSeverity * 0.32 +
                                  oilConditionSeverity * 0.09 + integritySeverity * 0.06 + lubricationThermalSeverity * 0.15 +
                                  ignitionSeverity * 0.04
  local roughnessCoef = 1 + (1 - torqueHoldCoef) * 0.95 + maintenancePenalty * 0.12 + wear.normalizedWear * 0.06 +
                            oilStarvationSeverity * 0.42 + oilConditionSeverity * 0.14 + integritySeverity * 0.22 +
                            lubricationThermalSeverity * 0.18 + ignitionSeverity * 0.38
  local ignitionErrorChance = common.clamp(
    max(env.avgMiles - 170000, 0) / 240000 * 0.006 + common.clamp(maintenancePenalty - 0.5, 0, 1) * 0.012 +
        oilStarvationSeverity * 0.025 + oilConditionSeverity * 0.01 + integritySeverity * 0.012 +
        lubricationThermalSeverity * 0.012 + ignitionSeverity * 0.045,
    0,
    0.085
  )
  local symptomBaseRate = neglectSeverity * (0.005 + wear.normalizedWear * 0.005) + oilStarvationSeverity * 0.016 +
                              integritySeverity * 0.008 + lubricationThermalSeverity * 0.018 + ignitionSeverity * 0.015
  local symptomRate = symptomBaseRate *
                          (0.24 + loadFactor * 0.42 + heatFactor * 0.14 + rpmFactor * 0.12 +
                              common.clamp(limitStressFactor, 0, 1.4) * 0.2)

  if pistonRingsDamaged then
    local rpmCapacity = common.clamp(tonumber(env.rpmCapacity) or tonumber(env.rpmFactor) or 0, 0, 1.35)
    local rpmOilLossFactor = 0.35 + rpmCapacity * 1.7 + max(rpmCapacity - 0.82, 0) * 2.8
    local heatOilLossFactor = 1 + heatFactor * 0.45 + common.clamp(env.overheatFactor or 0, 0, 1) * 0.8
    pistonRingOilConsumptionRate = pistonRingOilLossPerSecond.fresh * rpmOilLossFactor * heatOilLossFactor *
                                       oilLevelMileageMultiplier * oilCapacityFactor
  end

  local hardFailureRate = 0
  local hardFailureIntegrityBias = common.clamp(integritySeverity * 0.75 + (1 - torqueHoldCoef) * 0.35, 0, 1.35)
  if catastrophicOilStarvation then
    hardFailureRate = 0.90 + hardFailureIntegrityBias * 0.42 + lubricationThermalSeverity * 0.22 + loadFactor * 0.95 +
                          rpmFactor * 0.72 + heatFactor * 0.55
  elseif severeOilStarvation then
    hardFailureRate = 0.07 + oilStarvationSeverity * 0.16 + hardFailureIntegrityBias * 0.08 + lubricationThermalSeverity * 0.07 +
                          loadFactor * 0.12 + rpmFactor * 0.07 + heatFactor * 0.06
  elseif oilConditionSeverity >= 0.38 then
    hardFailureRate = 0.008 + oilConditionSeverity * 0.032 + hardFailureIntegrityBias * 0.016 + lubricationThermalSeverity * 0.02 +
                          loadFactor * 0.018 + rpmFactor * 0.015
  elseif oilStarvationSeverity >= 0.42 and integritySeverity >= 0.25 then
    hardFailureRate = 0.010 + oilStarvationSeverity * 0.03 + hardFailureIntegrityBias * 0.022 + lubricationThermalSeverity * 0.02 +
                          loadFactor * 0.018 + rpmFactor * 0.015
  elseif lubricationThermalSeverity >= 0.95 then
    hardFailureRate = 0.012 + lubricationThermalSeverity * 0.03 + hardFailureIntegrityBias * 0.016 + loadFactor * 0.02 +
                          rpmFactor * 0.02
  end
  local oilConditionInterval = maintenanceIntervals.oilCondition.fresh * classConditionIntervalMultiplier * dieselIntervalMultiplier
  local oilLevelInterval = maintenanceIntervals.oilLevel.fresh
  local ignitionInterval = maintenanceIntervals.ignitionService.fresh
  local oilConditionEffectiveMultiplier = driveMultipliers.normalized.oilCondition * oilTemperatureMultiplier *
                                            lowOilConditionMultiplier * (1 + torqueCapacityStress * 4) * dieselLoadMultiplier
  local extremeOutputGate = getExtremeOutputGate(env)
  local extremePowerMultiplier = getExtremePowerMultiplier(env.powerHp)
  local oilLevelEffectiveMultiplier = (driveMultipliers.normalized.oilLevel * oilLevelMileageMultiplier *
                                          (1 + torqueCapacityStress * 1.5) * dieselOilLevelMultiplier +
                                          extremeOutputGate * max(extremePowerMultiplier - 1, 0)) * oilCapacityFactor
  local averageDriveMultiplier = (oilConditionEffectiveMultiplier + oilLevelEffectiveMultiplier +
                                     driveMultipliers.normalized.ignitionService) / 3

  return {
    wear = wear,
    maintenanceAvg = maintenanceAvg,
    maintenancePenalty = maintenancePenalty,
    neglectSeverity = neglectSeverity,
    oilCondition = oilCondition,
    oilLevel = oilLevel,
    ignitionService = ignitionService,
    integrityValue = integrityValue,
    integritySeverity = integritySeverity,
    oilTemp = oilTemp,
    oilHeatFactor = oilHeatFactor,
    oilOverheatFactor = oilOverheatFactor,
    oilLevelDriveSeverity = oilLevelDriveSeverity,
    oilConditionDriveSeverity = oilConditionDriveSeverity,
    ignitionSeverity = ignitionSeverity,
    lubricationDriveSeverity = lubricationDriveSeverity,
    lubricationThermalSeverity = lubricationThermalSeverity,
    lubricationCollapseSeverity = lubricationCollapseSeverity,
    criticalOilFailureSeverity = criticalOilFailureSeverity,
    cylinderWallThreatSeverity = cylinderWallThreatSeverity,
    oilStarvationSeverity = oilStarvationSeverity,
    oilConditionSeverity = oilConditionSeverity,
    severeOilStarvation = severeOilStarvation,
    catastrophicOilStarvation = catastrophicOilStarvation,
    dryOilLockup = dryOilLockup,
    torqueHoldCoef = torqueHoldCoef,
    powerHoldCoef = powerHoldCoef,
    frictionCoef = frictionCoef,
    dynamicFrictionCoef = dynamicFrictionCoef,
    roughnessCoef = roughnessCoef,
    ignitionErrorChance = ignitionErrorChance,
    symptomRate = symptomRate,
    hardFailureRate = hardFailureRate,
    pistonRingsDamaged = pistonRingsDamaged,
    pistonRingOilConsumptionRate = pistonRingOilConsumptionRate,
    profile = common.deepCopy(profile),
    mileageAgeIndex = common.getMileageAgeIndex(env.avgMiles),
    oilCapacityFactor = oilCapacityFactor,
    oilTemperatureMultiplier = oilTemperatureMultiplier,
    lowOilConditionMultiplier = lowOilConditionMultiplier,
    torqueCapacityStress = torqueCapacityStress,
    torqueCapacityRatio = torqueCapacityRatio,
    maxTorqueRating = tonumber(env.maxTorqueRating) or -1,
    combustionTorque = tonumber(env.combustionTorque) or 0,
    extremeOutputGate = extremeOutputGate,
    extremePowerMultiplier = extremePowerMultiplier,
    ageWearSeverity = ageWearSeverity,
    ageWearFrictionCoef = ageWearFrictionCoef,
    ageWearDynamicFrictionCoef = ageWearDynamicFrictionCoef,
    ageWearIdleErrorCoef = ageWearIdleErrorCoef,
    limitStressFactor = limitStressFactor,
    driveMultiplier = averageDriveMultiplier,
    driveMultipliers = common.deepCopy(driveMultipliers.normalized),
    rawDriveMultipliers = common.deepCopy(driveMultipliers.raw),
    oilConditionStressMultiplier = effectiveDrainMultipliers.oilConditionStressMultiplier,
    oilLevelMileageMultiplier = oilLevelMileageMultiplier,
    serviceTargets = common.deepCopy(serviceTargetValues),
    effectiveIntervals = {
      oilCondition = oilConditionInterval / max(oilConditionEffectiveMultiplier, 0.0001),
      oilLevel = oilLevelInterval / max(oilLevelEffectiveMultiplier, 0.0001),
      ignitionService = ignitionInterval / max(driveMultipliers.normalized.ignitionService, 0.0001)
    },
    serviceDueMilesRemaining = {
      oilCondition = common.estimateMilesToTarget(state.maintenance.oilCondition or 1, oilConditionInterval, oilConditionEffectiveMultiplier, serviceTargetValues.oilCondition),
      oilLevel = common.estimateMilesToTarget(state.maintenance.oilLevel or 1, oilLevelInterval, oilLevelEffectiveMultiplier, serviceTargetValues.oilLevel),
      ignitionService = common.estimateMilesToTarget(state.maintenance.ignitionService or 1, ignitionInterval, driveMultipliers.normalized.ignitionService, serviceTargetValues.ignitionService)
    }
  }
end

local function getActiveSymptom(runtime)
  if runtime and runtime.activeSymptom and (runtime.symptomTimer or 0) > 0 then
    return runtime.activeSymptom
  end
end

local function selectSymptom(derived, env)
  local loadFactor = common.clamp(env.loadFactor or 0, 0, 1)
  local heatFactor = common.clamp(env.heatFactor or 0, 0, 1)
  local maintenancePenalty = derived.maintenancePenalty
  local tickingWeight = max(
    (derived.oilStarvationSeverity or 0) * 2.4 + (derived.oilConditionDriveSeverity or 0) * 1.1 +
        (derived.lubricationDriveSeverity or 0) * 0.85 + (derived.integritySeverity or 0) * 0.55 - 0.18,
    0
  )
  local stallWeight = max((maintenancePenalty - 0.18) * 6 + (1 - loadFactor) * 0.4 + max(heatFactor - 0.45, 0), 0)
  return common.chooseWeighted({
    {value = 'roughRunning', weight = 1 + maintenancePenalty + (derived.oilStarvationSeverity or 0) * 1.4},
    {value = 'ticking', weight = tickingWeight},
    {value = 'roughIdle', weight = 1.3 + maintenancePenalty * 1.4 + (1 - loadFactor)},
    {value = 'torqueDip', weight = 1 + loadFactor * 2.4},
    {value = 'powerFade', weight = 1 + loadFactor * 1.6 + heatFactor * 1.6},
    {value = 'stall', weight = stallWeight}
  })
end

local function stepRuntime(runtime, state, derived, env, dt)
  runtime.cooldownTimer = max((runtime.cooldownTimer or 0) - dt, 0)
  runtime.symptomTimer = max((runtime.symptomTimer or 0) - dt, 0)
  runtime.criticalOilSeconds = max((runtime.criticalOilSeconds or 0) - dt * 0.2, 0)
  runtime.dryOilSeconds = max((runtime.dryOilSeconds or 0) - dt * 0.1, 0)
  runtime.lubricationDamageStage = max((runtime.lubricationDamageStage or 0) - dt * 0.04, 0)
  runtime.forceHardFailure = false
  runtime.forceHardFailureTarget = nil
  runtime.forceHardFailurePersistent = false
  runtime.forceHardFailureReason = nil

  if runtime.symptomTimer <= 0 then
    runtime.activeSymptom = nil
    runtime.stallApplied = false
  end

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and derived.dryOilLockup then
    local dryOilLoad = 1.2 + common.clamp(env.loadFactor or 0, 0, 1) * 1.4 + common.clamp(env.rpmFactor or 0, 0, 1) * 1.6
    runtime.dryOilSeconds = runtime.dryOilSeconds + dt * dryOilLoad
    runtime.activeSymptom = 'stall'
    runtime.symptomTimer = max(runtime.symptomTimer or 0, 1.6)
    runtime.cooldownTimer = max(runtime.cooldownTimer or 0, 4.0)

    if runtime.dryOilSeconds >= 0.35 then
      runtime.forceHardFailure = true
      runtime.forceHardFailureTarget = 'engine'
      runtime.forceHardFailurePersistent = true
      runtime.forceHardFailureReason = 'oil_lockup'
      state.lastFailureTime = os.time()
      state.lastFailureType = 'engine_lockup'
      return 'stall'
    end
  end

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and
      ((derived.lubricationDriveSeverity or 0) >= 0.32 or (derived.lubricationCollapseSeverity or 0) >= 0.38 or (derived.oilStarvationSeverity or 0) >= 0.2 or
          (derived.oilConditionSeverity or 0) >= 0.24) then
    local lubricationLoad = 0.008 + common.clamp(env.loadFactor or 0, 0, 1) * 0.032 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.026 +
                                common.clamp(derived.lubricationDriveSeverity or 0, 0, 1.8) * 0.028 +
                                common.clamp(derived.oilHeatFactor or 0, 0, 1) * 0.028 +
                                common.clamp(derived.oilOverheatFactor or 0, 0, 1) * 0.045
    local oilCollapseLoad = common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.030 +
                                common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.028 +
                                ((derived.severeOilStarvation or false) and 0.030 or 0) +
                                ((derived.catastrophicOilStarvation or false) and 0.090 or 0) +
                                ((derived.dryOilLockup or false) and 0.180 or 0)
    local minimumStage = common.clamp((derived.lubricationCollapseSeverity or 0) * 0.06 +
                                          max((derived.lubricationDriveSeverity or 0) - 0.5, 0) * 0.10 +
                                          common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.10 +
                                          common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.16,
      0,
      1.25
    )
    runtime.lubricationDamageStage = min(
      1.8,
      max(runtime.lubricationDamageStage or 0, minimumStage) + dt * (lubricationLoad + oilCollapseLoad)
    )

    if not getActiveSymptom(runtime) and
        ((derived.oilStarvationSeverity or 0) >= 0.35 or (derived.lubricationDriveSeverity or 0) >= 0.55) then
      runtime.activeSymptom = 'ticking'
      runtime.symptomTimer = max(runtime.symptomTimer or 0, common.pickDuration(2.5, 5.0))
      runtime.cooldownTimer = max(runtime.cooldownTimer or 0, runtime.symptomTimer + common.pickDuration(1.5, 4.0))
      state.lastFailureTime = os.time()
      state.lastFailureType = runtime.activeSymptom
    end
  end

  if env.engineRunningSeconds and env.engineRunningSeconds > 0 and
      (derived.severeOilStarvation or derived.catastrophicOilStarvation or
          ((derived.lubricationThermalSeverity or 0) >= 0.95 and
              ((derived.oilStarvationSeverity or 0) >= 0.28 or (derived.oilConditionSeverity or 0) >= 0.35))) then
    local criticalLoad = 0.18 + common.clamp(env.loadFactor or 0, 0, 1) * 0.48 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.44 +
                             common.clamp(env.heatFactor or 0, 0, 1) * 0.18 +
                             common.clamp(derived.oilHeatFactor or 0, 0, 1) * 0.20 +
                             common.clamp(derived.oilOverheatFactor or 0, 0, 1) * 0.34
    runtime.criticalOilSeconds = runtime.criticalOilSeconds + dt * criticalLoad

    if runtime.criticalOilSeconds >= 1.25 then
      runtime.activeSymptom = 'stall'
      runtime.symptomTimer = max(runtime.symptomTimer or 0, 1.2)
      runtime.cooldownTimer = max(runtime.cooldownTimer or 0, 3.5)
      state.lastFailureTime = os.time()
      state.lastFailureType = runtime.activeSymptom
    end

    local collapseSeverity = common.clamp(
      (derived.integritySeverity or 0) * 0.9 + (1 - (derived.torqueHoldCoef or 1)) * 0.45 +
          (derived.lubricationThermalSeverity or 0) * 0.5,
      0,
      1.8
    )
    local loadThreat = common.clamp(env.loadFactor or 0, 0, 1) * 0.65 + common.clamp(env.rpmFactor or 0, 0, 1) * 0.5
    local catastrophicThreshold = derived.catastrophicOilStarvation and
                                      max(1.1, 2.8 - collapseSeverity * 0.65 - loadThreat * 0.35) or
                                      max(3.2, 7.2 - collapseSeverity * 1.2 - loadThreat * 0.9)
    if runtime.criticalOilSeconds >= catastrophicThreshold then
      runtime.forceHardFailure = true
      runtime.forceHardFailureTarget = 'engine'
      runtime.forceHardFailurePersistent = false
      runtime.forceHardFailureReason = derived.catastrophicOilStarvation and 'oil_starvation' or 'maintenance_failure'
      state.lastFailureTime = os.time()
      state.lastFailureType = 'engine_break'
      return 'stall'
    end
  end

  if runtime.cooldownTimer <= 0 and not getActiveSymptom(runtime) and common.rollChance(derived.symptomRate, dt) then
    runtime.activeSymptom = selectSymptom(derived, env)
    runtime.symptomTimer = common.pickDuration(symptomDurations[runtime.activeSymptom][1], symptomDurations[runtime.activeSymptom][2])
    runtime.cooldownTimer = runtime.symptomTimer + common.pickDuration(8, 18)
    state.lastFailureTime = os.time()
    state.lastFailureType = runtime.activeSymptom
  end

  return getActiveSymptom(runtime)
end

local function updateAudio(context, runtime, derived, dt)
  if not runtime or not derived then
    return
  end

  local symptom = getActiveSymptom(runtime)
  local knockSeverity = max(derived.oilStarvationSeverity or 0, (derived.oilConditionSeverity or 0) * 0.7)
  local shouldTick = symptom == 'roughRunning' or symptom == 'ticking' or derived.severeOilStarvation or
                         derived.catastrophicOilStarvation or knockSeverity >= 0.18
  if not shouldTick or type(context) ~= "table" or type(sounds) ~= "table" or type(sounds.playSoundOnceFollowNode) ~= "function" then
    runtime.knockSoundTick = 0
    return
  end

  local entry = context.devices and context.devices[1] or nil
  local engine = entry and entry.device or nil
  if type(engine) ~= "table" then
    runtime.knockSoundTick = 0
    return
  end

  local soundNode = engine.engineNodeID or (type(engine.engineBlockNodes) == "table" and engine.engineBlockNodes[1]) or
                        (type(nodes) == "table" and type(nodes.engine) == "table" and nodes.engine[1]) or nil
  if not soundNode then
    runtime.knockSoundTick = 0
    return
  end

  local absEngineAV = abs(engine.outputAV1 or engine.inputAV or engine.outputAV2 or 0)
  if absEngineAV < 15 then
    runtime.knockSoundTick = 0
    return
  end

  local severity = common.clamp(knockSeverity + ((symptom == 'roughRunning' or symptom == 'ticking') and 0.22 or 0), 0, 1.6)
  local tickRate = 0.2 + absEngineAV * 0.008333 * (0.5 + severity)
  runtime.knockSoundTick = (runtime.knockSoundTick or 0) + dt * tickRate
  if runtime.knockSoundTick > 1 then
    runtime.knockSoundTick = runtime.knockSoundTick - 1
    local volume = common.clamp(0.3 + severity * 0.5, 0.25, 1)
    sounds.playSoundOnceFollowNode("event:>Vehicle>Failures>failure_engine_knock", soundNode, volume)
  end
end

local function apply(context, state, runtime, derived)
  local symptom = getActiveSymptom(runtime)
  local symptomTorqueCoef = 1
  local symptomPowerCoef = 1
  local symptomFrictionCoef = 1
  local symptomRoughnessCoef = 1
  local symptomIgnitionBonus = 0

  if symptom == 'roughRunning' or symptom == 'ticking' then
    symptomRoughnessCoef = 1.1
  elseif symptom == 'roughIdle' then
    symptomRoughnessCoef = 1.32
    symptomIgnitionBonus = 0.018
  elseif symptom == 'torqueDip' then
    symptomTorqueCoef = 0.94
  elseif symptom == 'powerFade' then
    symptomPowerCoef = 0.9
    symptomTorqueCoef = 0.96
    symptomFrictionCoef = 1.03
  elseif symptom == 'stall' then
    symptomPowerCoef = 0.7
    symptomTorqueCoef = 0.65
    symptomRoughnessCoef = 1.55
    symptomFrictionCoef = 1.05
    symptomIgnitionBonus = 0.045
  end

  runtime.lastPowerLimitReason = nil
  runtime.lastPowerLimitActive = false

  for _, entry in ipairs(context.devices or {}) do
    local engine = entry.device
    local base = entry.base
    local lubricationDamageStage = common.clamp(runtime.lubricationDamageStage or 0, 0, 1.8)
    local directDriveSeverity = common.clamp(
      max(derived.lubricationDriveSeverity or 0, lubricationDamageStage * 0.92, (derived.ignitionSeverity or 0) * 0.35),
      0,
      1.8
    )
    resetEngineState(engine, base, derived)

    if base.friction ~= nil then
      engine.friction = base.friction * derived.frictionCoef * symptomFrictionCoef
    end
    if base.dynamicFriction ~= nil then
      engine.dynamicFriction = base.dynamicFriction * derived.dynamicFrictionCoef * symptomFrictionCoef
    end
    if engine.fastIgnitionErrorChance ~= nil then
      engine.fastIgnitionErrorChance = common.clamp(derived.ignitionErrorChance + symptomIgnitionBonus, 0, 0.12)
    end
    if engine.slowIgnitionErrorChance ~= nil then
      engine.slowIgnitionErrorChance = common.clamp(derived.ignitionErrorChance + symptomIgnitionBonus * 1.15, 0, 0.12)
    end

    local baseMaxTorque = base.maxTorque or engine.maxTorque or 0
    local baseMaxPowerRaw = base.maxPower or engine.maxPower or 0
    local baseMaxPowerWatts = common.getBeamPowerWatts(baseMaxPowerRaw)
    local engineAV = max(abs(engine.outputAV1 or engine.inputAV or engine.outputAV2 or 0), 1)
    local redlineAV = max(base.maxAV or engine.maxAV or 0, 1)
    local rpmCapacity = engineAV / redlineAV
    local liveTorqueHoldCoef = getLiveTorqueHoldCoef(derived.torqueHoldCoef, derived.loadFactor, rpmCapacity)
    local lubricationTorqueCapCoef = common.sampleCurve(directDriveSeverity, {
      {0.0, 1.0},
      {0.18, 0.97},
      {0.35, 0.89},
      {0.55, 0.75},
      {0.80, 0.56},
      {1.10, 0.36},
      {1.45, 0.16},
      {1.80, 0.03}
    })
    local torqueCap = baseMaxTorque * liveTorqueHoldCoef * symptomTorqueCoef * lubricationTorqueCapCoef
    local appliedLimit = torqueCap

    -- Only apply the horsepower ceiling when the engine exposes a useful base power value
    -- and is already in the higher-RPM range where a power cap makes sense.
    local shouldUsePowerCap = baseMaxPowerWatts > 0 and engineAV > 220 and
                                   (symptom == 'powerFade' or symptom == 'stall' or directDriveSeverity >= 0.35 or
                                       (derived.ignitionSeverity or 0) >= 0.45)
    if shouldUsePowerCap then
      local powerFloorCoef = common.sampleCurve(directDriveSeverity, {
        {0.0, 0.62},
        {0.35, 0.52},
        {0.70, 0.36},
        {1.10, 0.22},
        {1.50, 0.10},
        {1.80, 0.04}
      })
      local powerTorqueCap = max((baseMaxPowerWatts * derived.powerHoldCoef * symptomPowerCoef) / engineAV, baseMaxTorque * powerFloorCoef)
      appliedLimit = min(torqueCap, powerTorqueCap)
      if powerTorqueCap < torqueCap - 0.001 then
        runtime.lastPowerLimitReason = getPowerLimitReason(derived, symptom, directDriveSeverity, true, lubricationDamageStage)
        runtime.lastPowerLimitActive = true
      end
    end

    if not runtime.lastPowerLimitReason and torqueCap < baseMaxTorque * 0.995 then
      runtime.lastPowerLimitReason = getPowerLimitReason(derived, symptom, directDriveSeverity, false, lubricationDamageStage)
      runtime.lastPowerLimitActive = true
    end

    if base.originalMaxTorqueLimit and base.originalMaxTorqueLimit < math.huge then
      appliedLimit = min(appliedLimit, base.originalMaxTorqueLimit)
    end

    local floorSeverity = common.clamp(
      max(derived.oilStarvationSeverity or 0, (derived.oilConditionSeverity or 0) * 0.7, (derived.integritySeverity or 0) * 0.9,
        lubricationDamageStage * 0.95, directDriveSeverity * 0.85),
      0,
      1.6
    )
    local minimumLimitCoef = common.sampleCurve(floorSeverity, {
      {0.0, symptom == 'stall' and 0.18 or 0.42},
      {0.30, symptom == 'stall' and 0.14 or 0.30},
      {0.65, symptom == 'stall' and 0.09 or 0.18},
      {1.00, symptom == 'stall' and 0.05 or 0.10},
      {1.35, symptom == 'stall' and 0.02 or 0.05},
      {1.60, symptom == 'stall' and 0.01 or 0.03}
    })
    local minimumLimit = baseMaxTorque * minimumLimitCoef
    engine.maxTorqueLimit = max(appliedLimit, minimumLimit)
    engine.idleAVReadErrorRangeHalf = (base.idleAVReadErrorRangeHalf or engine.idleAVReadErrorRangeHalf or 0) *
                                          derived.roughnessCoef * symptomRoughnessCoef
    engine.idleAVReadErrorRange = (base.idleAVReadErrorRange or engine.idleAVReadErrorRange or 0) *
                                      derived.roughnessCoef * symptomRoughnessCoef

    if engine.thermals and engine.thermals.oilTemperature ~= nil then
      local oilThermalSeverity = common.clamp(
        (derived.lubricationThermalSeverity or 0) * 0.55 + lubricationDamageStage * 0.35 + (derived.oilStarvationSeverity or 0) * 0.32 +
            (derived.oilConditionSeverity or 0) * 0.22 + common.clamp(derived.loadFactor or 0, 0, 1) * 0.08 +
            common.clamp(derived.rpmFactor or 0, 0, 1) * 0.06,
        0,
        1.45
      )
      local oilFailureHeatSeverity = common.clamp(
        max(
          oilThermalSeverity,
          common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.72 +
              common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.26
        ),
        0,
        2.4
      )
      local thermalInterventionSeverity = common.clamp(common.linearScale(oilFailureHeatSeverity, 0.28, 1.45, 0, 1), 0, 1)
      if thermalInterventionSeverity > 0 then
        local currentOilTemp = tonumber(engine.thermals.oilTemperature) or 0
        local targetOilTemp = common.lerp(112, 192, thermalInterventionSeverity) +
                                  common.clamp(derived.loadFactor or 0, 0, 1) * 3 +
                                  common.clamp(derived.rpmFactor or 0, 0, 1) * 4 +
                                  common.clamp(derived.oilStarvationSeverity or 0, 0, 1.35) * 10 +
                                  common.clamp(derived.oilConditionSeverity or 0, 0, 0.75) * 6 +
                                  common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 16 +
                                  ((derived.catastrophicOilStarvation or false) and 14 or 0) +
                                  ((derived.dryOilLockup or false) and 24 or 0)
        if targetOilTemp > currentOilTemp then
          local tempRiseRate = (derived.catastrophicOilStarvation or derived.dryOilLockup) and 0.08 or
                                   (((derived.severeOilStarvation or false) or (derived.criticalOilFailureSeverity or 0) >= 1.2) and 0.045 or 0.02)
          engine.thermals.oilTemperature = common.lerp(currentOilTemp, targetOilTemp, tempRiseRate)
        end
      end

      local starvationDamageStage = common.clamp(
        lubricationDamageStage + common.clamp(derived.criticalOilFailureSeverity or 0, 0, 2.25) * 0.34 +
            common.clamp(derived.cylinderWallThreatSeverity or 0, 0, 2.8) * 0.22,
        0,
        2.6
      )

      if starvationDamageStage >= 0.24 and engine.thermals.pistonRingsDamaged ~= nil then
        engine.thermals.pistonRingsDamaged = true
      end
      if starvationDamageStage >= 0.52 and engine.thermals.connectingRodBearingsDamaged ~= nil then
        engine.thermals.connectingRodBearingsDamaged = true
      end
      if starvationDamageStage >= 0.88 and engine.thermals.cylinderWallsMelted ~= nil then
        engine.thermals.cylinderWallsMelted = true
      end
      if starvationDamageStage >= 1.38 and engine.thermals.engineBlockMelted ~= nil then
        engine.thermals.engineBlockMelted = true
      end
    end

    if (symptom == 'stall' or lubricationDamageStage >= 1.45) and not runtime.stallApplied then
      engine.isStalled = true
      engine.stallTimer = 0
      runtime.stallApplied = true
    end
  end
end

local function getHardFailureState(reason)
  local isCoolingFailure = reason == 'cooling_failure' or reason == 'head_gasket_failure'

  return {
    damageFrictionCoef = 2.5,
    damageDynamicFrictionCoef = 3.5,
    damageIdleAVReadErrorRangeCoef = 32,
    fastIgnitionErrorChance = 0.35,
    slowIgnitionErrorChance = 0.35,
    thermals = {
      headGasketBlown = isCoolingFailure,
      pistonRingsDamaged = not isCoolingFailure,
      connectingRodBearingsDamaged = not isCoolingFailure,
      engineBlockMelted = false,
      cylinderWallsMelted = not isCoolingFailure
    },
    isBroken = true
  }
end

local function clearFailureRuntime(context)
  local runtime = context.runtime or nil
  if type(runtime) == "table" then
    runtime.knockSoundTick = 0
    runtime.criticalOilSeconds = 0
    runtime.dryOilSeconds = 0
    runtime.lubricationDamageStage = 0
    runtime.forceHardFailure = false
    runtime.forceHardFailureTarget = nil
    runtime.forceHardFailurePersistent = false
    runtime.forceHardFailureReason = nil
  end

  for _, entry in ipairs(context.devices or {}) do
    local engine = entry.device
    local base = entry.base or {}
    resetEngineState(engine, base)

    if engine.isStalled ~= nil then
      engine.isStalled = false
    end
    if engine.stallTimer ~= nil then
      engine.stallTimer = 0
    end

    if type(engine.thermals) == "table" then
      if engine.thermals.headGasketBlown ~= nil then
        engine.thermals.headGasketBlown = false
      end
      if engine.thermals.pistonRingsDamaged ~= nil then
        engine.thermals.pistonRingsDamaged = false
      end
      if engine.thermals.connectingRodBearingsDamaged ~= nil then
        engine.thermals.connectingRodBearingsDamaged = false
      end
      if engine.thermals.engineBlockMelted ~= nil then
        engine.thermals.engineBlockMelted = false
      end
      if engine.thermals.cylinderWallsMelted ~= nil then
        engine.thermals.cylinderWallsMelted = false
      end
    end
  end
end

M.getDefaultMaintenance = getDefaultMaintenance
M.getLiveTorqueHoldCoef = getLiveTorqueHoldCoef
M.drainMaintenance = drainMaintenance
M.buildDerived = buildDerived
M.stepRuntime = stepRuntime
M.apply = apply
M.updateAudio = updateAudio
M.getHardFailureState = getHardFailureState
M.clearFailureRuntime = clearFailureRuntime
M.minimumHardFailureMileage = minimumHardFailureMileage

return M
