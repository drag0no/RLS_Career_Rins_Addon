local M = {}

local rtState = require('ge/extensions/career/modules/business/racingTeamRuntimeState')
local racingTeamBuildClass = require('ge/extensions/career/modules/business/racingTeamBuildClass')
local jbeamIO = require('jbeam/io')

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

-- === Catalog / part value lookups
function M.getCatalogVehicleInfo(model_key, config_key)
  if not model_key or not config_key then
    return nil
  end
  if not rtState.rtInternal.eligibleVehicleInfoByPair then
    rtState.rtInternal.eligibleVehicleInfoByPair = {}
    local list = util_configListGenerator and util_configListGenerator.getEligibleVehicles(false, false) or {}
    for _, vi in ipairs(list) do
      if vi.model_key and vi.key then
        rtState.rtInternal.eligibleVehicleInfoByPair[vi.model_key .. "\0" .. vi.key] = vi
      end
    end
  end
  local vi = rtState.rtInternal.eligibleVehicleInfoByPair[model_key .. "\0" .. config_key]
  if vi then
    return vi
  end
  local stripped = tostring(config_key):match("^(.+)%.pc$")
  if stripped then
    vi = rtState.rtInternal.eligibleVehicleInfoByPair[model_key .. "\0" .. stripped]
    if vi then
      return vi
    end
  end
  return nil
end

local function sumInstalledPartsTreeJbeamValue(partsTree, modelKey, logContext)
  if type(partsTree) ~= "table" or not modelKey or modelKey == "" then
    return nil
  end
  local ioCtx = { preloadedDirs = { "/vehicles/" .. tostring(modelKey) .. "/" } }
  local total = 0
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    local name = node.chosenPartName
    if type(name) == "string" and name ~= "" then
      local partData = jbeamIO.getPart(ioCtx, name)
      if partData and partData.information and partData.information.value then
        total = total + (tonumber(partData.information.value) or 0)
      end
    end
    local children = node.children
    if type(children) == "table" then
      for _, child in pairs(children) do
        walk(child)
      end
    end
  end
  local ok, err = pcall(function()
    walk(partsTree)
  end)
  if not ok then
    log("D", "Career", string.format(
      "sumInstalledPartsTreeJbeamValue failed (%s): %s",
      tostring(logContext or "racingTeamFleet"),
      tostring(err)))
    return nil
  end
  if total <= 0 then
    return nil
  end
  return total
end

-- === Book / sell value
function M.getTeamVehicleBookValue(vehicle)
  if type(vehicle) ~= "table" then
    return 0
  end

  local function getCatalogVehicleYear(cfg)
    if type(cfg) ~= "table" then
      return nil
    end
    local year = tonumber(cfg.Year)
    if year and year > 0 then
      return year
    end
    local years = cfg.Years or (cfg.aggregates and cfg.aggregates.Years)
    if type(years) == "table" then
      year = tonumber(years.min) or tonumber(years.max)
      if year and year > 0 then
        return year
      end
    elseif type(years) == "number" then
      if years > 0 then
        return years
      end
    end
    return nil
  end

  local function getCatalogVehicleBaseValue(cfg)
    if type(cfg) ~= "table" then
      return nil
    end
    local value = tonumber(cfg.Value)
      or tonumber(cfg.value)
      or tonumber(cfg["Base Value"])
      or tonumber(cfg.baseValue)
      or tonumber(cfg.Price)
      or tonumber(cfg.price)
    if value and value > 0 then
      return value
    end
    return nil
  end

  local vc = vehicle.vehicleConfig or {}
  local modelKey = vc.model_key or vehicle.model_key
  local configKey = vc.key or vc.config_key or vehicle.config_key
  local mileageMeters = tonumber(vehicle.mileage) or 0
  local purchasePrice = tonumber(vehicle.purchasePrice) or 0
  local estimate = nil

  local valueCalculator = career_modules_valueCalculator
  if valueCalculator and valueCalculator.getVehicleCatalogIntrinsicBookValue and modelKey and configKey then
    local cfg = M.getCatalogVehicleInfo(modelKey, configKey)
    local catalogBaseValue = getCatalogVehicleBaseValue(cfg)
    local vehicleYear = getCatalogVehicleYear(cfg)
    local nowYear = (os.date("*t") or {}).year or 2023
    local age = vehicleYear and math.max(0, nowYear - vehicleYear) or nil
    if catalogBaseValue and age ~= nil then
      local partsCatalogSum = nil
      local storedCfg = vehicle.config
      if type(storedCfg) == "table" and storedCfg.partsTree then
        partsCatalogSum = sumInstalledPartsTreeJbeamValue(storedCfg.partsTree, modelKey, "racingTeamFleet")
      end
      local opts = {
        catalogBaseValue = catalogBaseValue,
        mileageMeters = mileageMeters,
        age = age,
        modelName = modelKey,
        configKey = configKey,
        logContext = "racingTeam"
      }
      if partsCatalogSum then
        opts.partsCatalogSum = partsCatalogSum
      end
      estimate = valueCalculator.getVehicleCatalogIntrinsicBookValue(opts)
    end
  end

  estimate = tonumber(estimate)
  if estimate and estimate > 0 then
    return math.floor(estimate + 0.5)
  end
  if purchasePrice > 0 then
    return math.floor(purchasePrice + 0.5)
  end
  return 0
end

function M.getTeamVehicleSellValue(vehicle, fallbackValue)
  local value = M.getTeamVehicleBookValue(vehicle)
  if value <= 0 then
    value = math.max(0, math.floor(tonumber(fallbackValue) or 0))
  end
  local valueCalculator = career_modules_valueCalculator
  if valueCalculator and valueCalculator.getVehicleSellMarketMultiplier then
    local mult = tonumber(valueCalculator.getVehicleSellMarketMultiplier()) or 1
    value = value * mult
  end
  value = math.floor(math.max(0, value) + 0.5)
  if value <= 0 then
    local fallback = tonumber(fallbackValue) or 0
    if fallback > 0 then
      value = math.max(0, math.floor(fallback * 0.75))
    end
  end
  return value
end

-- === HP/weight/PW helpers
local function vehicleInfoPowerHp(vi)
  if not vi then
    return nil
  end
  local power = tonumber(vi.Power)
  if not power and vi.aggregates and vi.aggregates.Power then
    local agg = vi.aggregates.Power
    power = tonumber(agg.min) or tonumber(agg.max)
  end
  if power and power > 0 then
    return power
  end
  return nil
end

local function vehicleInfoWeightKg(vi)
  if not vi or type(vi) ~= "table" then
    return nil
  end
  local w = tonumber(vi.total_weight)
  if not w and vi.aggregates and vi.aggregates.total_weight then
    w = tonumber(vi.aggregates.total_weight)
  end
  if not w and vi.Weight then
    w = tonumber(vi.Weight)
  end
  if not w and vi.aggregates and vi.aggregates.Weight then
    local agg = vi.aggregates.Weight
    w = tonumber(agg.min) or tonumber(agg.max)
  end
  return w
end

local function hpPerKgFromHpAndWeightKg(hp, wkg)
  local h, w = tonumber(hp), tonumber(wkg)
  if not h or h <= 0 or not w or w <= 0 then
    return nil
  end
  return h / w
end

local function configWeightKgFromModelConfig(modelKey, configKey)
  if not core_vehicles or not core_vehicles.getConfig then return nil end
  local c = core_vehicles.getConfig(modelKey, configKey)
  if not c then return nil end
  
  return vehicleInfoWeightKg(c)
end

function M.getSanctionedStockPwCeiling()
  local sr = gameplay_events_freContracts_sanctionedRacing
  if sr and sr.getStockClassPwCeiling then
    local c = tonumber(sr.getStockClassPwCeiling())
    if c and c > 0 then
      return c
    end
  end
  return 0.2822
end

-- === Job-to-vehicle linkage
function M.inventoryVehicleLinkedToActiveRacingJob(businessId, vehicle)
  if not vehicle or vehicle.vehicleId == nil then
    return false
  end
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return false
  end
  local vid = tostring(tonumber(vehicle.vehicleId) or vehicle.vehicleId)
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  for _, v in ipairs(vehicles) do
    if tostring(tonumber(v.vehicleId) or v.vehicleId) == vid then
      return true
    end
  end
  return false
end

-- === Effective HP/PW per fleet vehicle (uses dyno peaks when present)
function M.getEffectiveTeamJobVehicleHp(businessId, vehicle)
  if not vehicle then
    return nil
  end
  local dyno = nil
  if vehicle.vehicleId ~= nil then
    local id = tostring(normalizeBusinessId(businessId))
    local peaks = rtState.classOptimizationPeakHpByBusiness[id]
    local rawPeak = peaks and peaks[tostring(vehicle.vehicleId)]
    if type(rawPeak) == "table" then
      dyno = tonumber(rawPeak.hp)
    else
      dyno = tonumber(rawPeak)
    end
  end
  
  local vc = vehicle.vehicleConfig
  local mk = vc and vc.model_key
  local ck = vc and (vc.key or vc.config_key)
  local catHp = nil
  if mk and ck then
    catHp = vehicleInfoPowerHp(M.getCatalogVehicleInfo(mk, ck))
  end
  
  local best = tonumber(dyno) or tonumber(catHp) or 0
  if best <= 0 then
    return nil
  end
  return best
end

function M.getEffectiveTeamJobVehiclePw(businessId, vehicle)
  local hp = M.getEffectiveTeamJobVehicleHp(businessId, vehicle)
  if not hp then
    return nil
  end
  local vc = vehicle and vehicle.vehicleConfig or {}
  local mk = vc.model_key or (vehicle and vehicle.model_key)
  local ck = vc.key or vc.config_key or (vehicle and vehicle.config_key)
  if not mk or not ck then
    return nil
  end
  local vi = M.getCatalogVehicleInfo(mk, ck)
  local idPw = tostring(normalizeBusinessId(businessId))
  local peaks = rtState.classOptimizationPeakHpByBusiness[idPw]
  local rawPeak = peaks and peaks[tostring(vehicle.vehicleId)]
  local dynoW = nil
  if type(rawPeak) == "table" then
    dynoW = tonumber(rawPeak.weightKg)
  end
  local wkg = dynoW or vehicleInfoWeightKg(vi) or configWeightKgFromModelConfig(mk, ck)
  return hpPerKgFromHpAndWeightKg(hp, wkg)
end

function M.getBestTeamJobVehicleHp(businessId)
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return nil
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  local best = nil
  for _, v in ipairs(vehicles) do
    local hp = M.getEffectiveTeamJobVehicleHp(businessId, v)
    if hp and (not best or hp > best) then
      best = hp
    end
  end
  return best
end

function M.getBestTeamJobVehiclePw(businessId)
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return nil
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  local best = nil
  for _, v in ipairs(vehicles) do
    local pw = M.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and (not best or pw > best) then
      best = pw
    end
  end
  return best
end

-- === Sanctioned class branch resolution
function M.resolveFleetVehicleSanctionedBranch(businessId, vehicle)
  local pw = M.getEffectiveTeamJobVehiclePw(businessId, vehicle)
  local sr = gameplay_events_freContracts_sanctionedRacing
  local pwBr = "stock"
  if pw and sr and sr.getSanctionedBranchForPw then
    pwBr = sr.getSanctionedBranchForPw(pw)
  end
  local vc = vehicle and vehicle.vehicleConfig or {}
  local mk = vc.model_key or vehicle and vehicle.model_key
  local ck = vc.key or vc.config_key
  local pt = vehicle and vehicle.config and vehicle.config.partsTree
  if racingTeamBuildClass and racingTeamBuildClass.resolveSanctionedBranchForFleetVehicle then
    return racingTeamBuildClass.resolveSanctionedBranchForFleetVehicle(mk, pt, pwBr, ck)
  end
  return pwBr
end

function M.getSanctionedBranchFilterForBusiness(businessId)
  if not racingTeamBuildClass or not racingTeamBuildClass.ENABLED then
    local pw = M.getBestTeamJobVehiclePw(businessId)
    local sr = gameplay_events_freContracts_sanctionedRacing
    if sr and sr.getSanctionedBranchForPw then
      return sr.getSanctionedBranchForPw(pw)
    end
    return "stock"
  end
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    local pw = M.getBestTeamJobVehiclePw(businessId)
    local sr = gameplay_events_freContracts_sanctionedRacing
    if sr and sr.getSanctionedBranchForPw then
      return sr.getSanctionedBranchForPw(pw)
    end
    return "stock"
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  local bestR = 0
  for _, v in ipairs(vehicles) do
    local br = M.resolveFleetVehicleSanctionedBranch(businessId, v)
    local r = racingTeamBuildClass.branchRank and racingTeamBuildClass.branchRank(br) or 0
    if r > bestR then
      bestR = r
    end
  end
  if bestR > 0 and racingTeamBuildClass.branchFromRank then
    return racingTeamBuildClass.branchFromRank(bestR)
  end
  local pw = M.getBestTeamJobVehiclePw(businessId)
  local sr = gameplay_events_freContracts_sanctionedRacing
  if sr and sr.getSanctionedBranchForPw then
    return sr.getSanctionedBranchForPw(pw)
  end
  return "stock"
end

function M.getRandomFleetVehicleSanctionedBranch(businessId)
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return M.getSanctionedBranchFilterForBusiness(businessId)
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  if #vehicles == 0 then
    return M.getSanctionedBranchFilterForBusiness(businessId)
  end
  local vPick = vehicles[math.random(1, #vehicles)]
  return M.resolveFleetVehicleSanctionedBranch(businessId, vPick)
end

-- === Damage
function M.getDamageThreshold(businessId)
  return 1500
end

function M.getSpawnedBusinessVehicleDamageInfo(businessId, vehicleId)
  local threshold = M.getDamageThreshold(businessId)
  local info = {
    locked = false,
    damage = 0,
    threshold = threshold
  }
  if not businessId or vehicleId == nil or not career_modules_business_businessInventory then
    return info
  end
  local getSid = career_modules_business_businessInventory.getSpawnedVehicleId
  if not getSid then
    return info
  end
  local spawnedId = getSid(businessId, vehicleId)
  if not spawnedId or not map or not map.objects then
    return info
  end
  local objectData = map.objects[spawnedId]
  if not objectData then
    return info
  end
  local damage = tonumber(objectData.damage) or 0
  info.damage = damage
  info.locked = damage >= threshold
  return info
end

-- === Cooldowns (fleet vehicle / driver / player)
function M.getRacingTeamPostRaceCooldownSeconds(businessId)
  businessId = normalizeBusinessId(businessId)
  local base = rtState.K.RACING_TEAM_POST_RACE_COOLDOWN_BASE_SEC
  if not businessId then
    return base
  end
  local lv = 0
  if rtState.rtInternal.getSkillTreeNodeLevel then
    lv = rtState.rtInternal.getSkillTreeNodeLevel(businessId, "driver", "cooldown") or 0
  end
  local mult = 1 - rtState.K.RACING_TEAM_COOLDOWN_REDUCTION_PER_LEVEL * lv
  mult = math.max(0.05, mult)
  return math.max(1, math.floor(base * mult + 0.5))
end

function M.getFleetVehiclePostRaceCooldownRemainingSec(businessId, vehicleId)
  if vehicleId == nil then
    return 0
  end
  local id = tostring(normalizeBusinessId(businessId))
  local vid = tostring(tonumber(vehicleId) or vehicleId)
  local rec = (rtState.vehicleCooldownByBusiness[id] or {})[vid]
  if type(rec) ~= "table" then
    return 0
  end
  local wallEpoch = tonumber(rec.wallEpoch)
  if wallEpoch and wallEpoch > 0 then
    local rem = wallEpoch - os.time()
    if rem <= 0 then
      return 0
    end
    return math.max(0, math.ceil(rem))
  end
  local untilSim = tonumber(rec.untilSim)
  if not untilSim then
    return 0
  end
  local now = rtState.rtInternal.getCareerSimTime()
  if now >= untilSim then
    return 0
  end
  return math.max(0, math.ceil(untilSim - now))
end

function M.armFleetVehiclePostRaceCooldown(businessId, vehicleId)
  if vehicleId == nil then
    return
  end
  local id = tostring(normalizeBusinessId(businessId))
  local vid = tostring(tonumber(vehicleId) or vehicleId)
  local cdSec = M.getRacingTeamPostRaceCooldownSeconds(businessId)
  rtState.vehicleCooldownByBusiness[id] = rtState.vehicleCooldownByBusiness[id] or {}
  rtState.vehicleCooldownByBusiness[id][vid] = {
    untilSim = rtState.rtInternal.getCareerSimTime() + cdSec,
    wallEpoch = os.time() + cdSec,
  }
end

function M.getRacingTeamPlayerPostRaceCooldownSeconds(businessId)
  businessId = normalizeBusinessId(businessId)
  local base = rtState.K.RACING_TEAM_PLAYER_POST_RACE_COOLDOWN_BASE_SEC
  if not businessId then
    return base
  end
  -- Player cooldown reuses the same "driver/cooldown" skill node so the
  -- node still feels meaningful when the player drives.
  local lv = 0
  if rtState.rtInternal.getSkillTreeNodeLevel then
    lv = rtState.rtInternal.getSkillTreeNodeLevel(businessId, "driver", "cooldown") or 0
  end
  local mult = 1 - rtState.K.RACING_TEAM_COOLDOWN_REDUCTION_PER_LEVEL * lv
  mult = math.max(0.05, mult)
  return math.max(1, math.floor(base * mult + 0.5))
end

function M.getPlayerPostRaceCooldownRemainingSec(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  local rec = rtState.playerCooldownByBusiness[id]
  if type(rec) ~= "table" then
    return 0
  end
  local wallEpoch = tonumber(rec.wallEpoch)
  if wallEpoch and wallEpoch > 0 then
    local rem = wallEpoch - os.time()
    if rem <= 0 then
      return 0
    end
    return math.max(0, math.ceil(rem))
  end
  local untilSim = tonumber(rec.untilSim)
  if not untilSim then
    return 0
  end
  local now = rtState.rtInternal.getCareerSimTime()
  if now >= untilSim then
    return 0
  end
  return math.max(0, math.ceil(untilSim - now))
end

function M.armPlayerPostRaceCooldown(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  if id == "nil" then
    return
  end
  local cdSec = M.getRacingTeamPlayerPostRaceCooldownSeconds(businessId)
  rtState.playerCooldownByBusiness[id] = {
    untilSim = rtState.rtInternal.getCareerSimTime() + cdSec,
    wallEpoch = os.time() + cdSec,
  }
end

function M.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech)
  if not tech then
    return 0
  end
  local wallEpoch = tonumber(tech.postRaceCooldownReadyWallEpoch)
  if wallEpoch and wallEpoch > 0 then
    local rem = wallEpoch - os.time()
    if rem <= 0 then
      return 0
    end
    return math.max(0, math.ceil(rem))
  end
  local untilSim = tonumber(tech.racingCooldownUntilSimTime)
  if not untilSim then
    return 0
  end
  local now = rtState.rtInternal.getCareerSimTime()
  if now >= untilSim then
    return 0
  end
  return math.max(0, math.ceil(untilSim - now))
end

function M.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
  if type(offer) ~= "table" then
    return
  end
  if offer.racingTeamBusinessOffer ~= true and offer.league1PlayerRace ~= true then
    return
  end
  local bid = offer.businessId
  if bid == nil or bid == "" then
    return
  end
  bid = normalizeBusinessId(bid)
  if not bid then
    return
  end
  local vid = tonumber(offer.requiredFleetVehicleId) or offer.requiredFleetVehicleId
    or tonumber(offer.fleetVehicleId) or offer.fleetVehicleId
  if vid ~= nil then
    M.armFleetVehiclePostRaceCooldown(bid, vid)
  end
  -- Only league-2+ "player races alongside proxy" arms the player cooldown.
  -- League 1 player races keep the prior fleet-only cooldown — gating it
  -- there would regress existing gameplay.
  if offer.playerProxyAlongsideRace == true then
    M.armPlayerPostRaceCooldown(bid)
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath and rtState.rtInternal.saveRacingTeamPersistedState then
    rtState.rtInternal.saveRacingTeamPersistedState(bid, savePath)
  end
end

-- === Cross-module exposure (rtInternal mirrors)
rtState.rtInternal.getTeamVehicleBookValue = M.getTeamVehicleBookValue
rtState.rtInternal.getSanctionedStockPwCeiling = M.getSanctionedStockPwCeiling
rtState.rtInternal.getEffectiveTeamJobVehiclePw = M.getEffectiveTeamJobVehiclePw
rtState.rtInternal.getBestTeamJobVehiclePw = M.getBestTeamJobVehiclePw
rtState.rtInternal.resolveFleetVehicleSanctionedBranch = M.resolveFleetVehicleSanctionedBranch
rtState.rtInternal.getSanctionedBranchFilterForBusiness = M.getSanctionedBranchFilterForBusiness
rtState.rtInternal.getRandomFleetVehicleSanctionedBranch = M.getRandomFleetVehicleSanctionedBranch

return M
