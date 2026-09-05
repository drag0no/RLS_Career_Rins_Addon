-- Off-Road Recovery career contracts.
-- Targets are temporary unowned inventory vehicles until delivered or abandoned.

local M = {}

M.dependencies = {
  "util_configListGenerator",
  "gameplay_sites_sitesManager",
  "freeroam_facilities"
}

local configListGenerator = require("util/configListGenerator")
local sitesManager = require("gameplay/sites/sitesManager")
local routeFactory = require("/lua/ge/extensions/gameplay/route/route")

local LOG_TAG = "offroadRecovery"
local SKILL_ATTRIBUTE = "careerSkills-recovery"
local SKILL_PATHS = {"careerSkills-recovery", "recovery"}
local FILTERS_FILE = "gameplay/offroadRecovery/offroadRecoveryVehicleFilters.json"
local SITES_NAME = "offroadRecovery"
local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = SAVE_DIR .. "/offroadRecovery.json"
local DAMAGE_DIR = SAVE_DIR .. "/offroadRecoveryDamage"
local OFFER_INTERVAL_MINUTES = 5
local OFFER_TTL_MINUTES = 15
local MAX_OFFERS = 3
local MAX_ACTIVE_PER_MAP = 3
local DELIVERY_RADIUS = 5
local DELIVERY_MAX_SPEED = 1
local SAVE_TIMEOUT_SECONDS = 15
local ASYNC_SAVE_EXTENSION = "offroadRecovery"
local MILES_TO_METERS = 1609.344
local MIN_TARGET_MILES = 100000
local MAX_TARGET_MILES = 300000

local state = {version = 1, maps = {}, nextId = 1}
local currentMap
local availableOffers = {}
local pendingOfferId
local nextOfferAt
local simMinutes = 0
local boardEligible = false
local sitesCache
local sitesCacheMap
local filterCache
local filterByTag
local vehiclePoolCache
local vehiclePoolSkillLevel
local runtimeByVehicleId = {}
local lastCompletion
local updateTimer = 0
local uiTimer = 0
local clearTasklistTimer = nil
local TASKLIST_CLEAR_SECONDS = 10
local initialized = false
local returnToOfferBoardAfterMap = false
local pendingCareerSave
local saveRegistered = false
local saveGenerationToken
local nextSaveToken = 0
local trackedRouteKey
local trackedRouteActive = false
local refreshTrackedRoute
local dropoffZonesByYardId = {}

local function tableCount(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local function toVec3Array(value)
  if not value then return nil end
  return {tonumber(value.x) or tonumber(value[1]) or 0, tonumber(value.y) or tonumber(value[2]) or 0, tonumber(value.z) or tonumber(value[3]) or 0}
end

local function toQuatArray(value)
  if not value then return nil end
  return {
    tonumber(value.x) or tonumber(value[1]) or 0,
    tonumber(value.y) or tonumber(value[2]) or 0,
    tonumber(value.z) or tonumber(value[3]) or 0,
    tonumber(value.w) or tonumber(value[4]) or 1
  }
end

local function arrayToVec3(value)
  return value and vec3(value[1] or 0, value[2] or 0, value[3] or 0) or vec3()
end

local function arrayToQuat(value)
  return value and quat(value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 1) or quat(0, 0, 0, 1)
end

local function currentSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentProfile then return nil end
  local _, savePath = career_saveSystem.getCurrentProfile()
  return savePath
end

local function ensureSaveDirectories(savePath)
  if not savePath then return end
  if not FS:directoryExists(savePath .. SAVE_DIR) then FS:directoryCreate(savePath .. SAVE_DIR) end
  if not FS:directoryExists(savePath .. DAMAGE_DIR) then FS:directoryCreate(savePath .. DAMAGE_DIR) end
end

local function damageFilePath(jobId, savePath)
  savePath = savePath or currentSavePath()
  if not savePath then return nil end
  ensureSaveDirectories(savePath)
  return string.format("%s%s/%s.json", savePath, DAMAGE_DIR, tostring(jobId):gsub("[^%w_%-]", "_"))
end

local function getMapState(mapId)
  if not mapId then return nil end
  state.maps[mapId] = state.maps[mapId] or {jobs = {}, trackedJobId = nil}
  state.maps[mapId].jobs = state.maps[mapId].jobs or {}
  return state.maps[mapId]
end

local function findJob(jobId)
  if not jobId then return nil end
  for mapId, mapState in pairs(state.maps or {}) do
    for _, job in ipairs(mapState.jobs or {}) do
      if job.id == jobId then return job, mapId, mapState end
    end
  end
end

local function findOffer(offerId)
  for index, offer in ipairs(availableOffers) do
    if offer.id == offerId then return offer, index end
  end
end

local function getSkillLevel()
  local level = 0
  if career_branches and career_branches.getBranchLevel then
    for _, pathId in ipairs(SKILL_PATHS) do
      level = math.max(level, tonumber((career_branches.getBranchLevel(pathId))) or 0)
    end
  end
  if level <= 0 and career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue
      and career_branches and career_branches.calcBranchLevelFromValue then
    local value = tonumber((career_modules_playerAttributes.getAttributeValue(SKILL_ATTRIBUTE))) or 0
    for _, pathId in ipairs(SKILL_PATHS) do
      level = math.max(level, tonumber((career_branches.calcBranchLevelFromValue(value, pathId))) or 0)
    end
  end
  return math.min(50, math.max(1, math.floor(level)))
end

local function getPayoutBonus(level)
  -- Keep early recovery work near its base payout, then ramp aggressively as
  -- the specialist skill matures. Level 50 reaches +800% (9x base payout).
  local clampedLevel = math.max(1, math.min(50, math.floor(tonumber(level) or 1)))
  -- Level 5 unlocks the activity without also granting its first payout step.
  -- The 22 odd-level rewards from 7 through 49 still reach the +800% cap.
  local rewardCount = math.max(0, math.min(22, math.floor((clampedLevel - 5) / 2)))
  local progress = rewardCount / 22
  return 8 * progress * progress
end

local function loadFilters()
  if filterCache then return filterCache, filterByTag end
  filterCache, filterByTag = {}, {}
  for id, raw in pairs(jsonReadFile(FILTERS_FILE) or {}) do
    if type(raw) == "table" and raw.type == "vehicle" then
      local item = deepcopy(raw)
      item.id = id
      item.unlockTag = item.unlockTag or id
      item.skillUnlockLevel = tonumber(item.skillUnlockLevel) or 50
      item.payMultiplier = tonumber(item.payMultiplier) or 1
      item.baseXp = tonumber(item.baseXp) or 0
      item.priority = tonumber(item.priority) or 0
      item.tierLabel = item.tierLabel or item.filterName or item.unlockTag
      filterCache[#filterCache + 1] = item
      filterByTag[item.unlockTag] = item
    end
  end
  table.sort(filterCache, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return tostring(a.id) < tostring(b.id)
  end)
  return filterCache, filterByTag
end

local function rangeValue(vehicleInfo, key)
  local direct = tonumber(vehicleInfo and vehicleInfo[key])
  if direct then return direct end
  local aggregate = vehicleInfo and type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[key]
  if type(aggregate) == "table" then return tonumber(aggregate.min) end
end

local function matchesFiltersList(vehicleInfo, filters)
  if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then return false end
  for key, expected in pairs(filters) do
    if type(expected) == "table" and (expected.min ~= nil or expected.max ~= nil) then
      local value = rangeValue(vehicleInfo, key)
      if not value then return false end
      if expected.min ~= nil and value < (tonumber(expected.min) or math.huge) then return false end
      if expected.max ~= nil and value > (tonumber(expected.max) or -math.huge) then return false end
    else
      if type(expected) ~= "table" then return false end
      local aggregate = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[key]
      local matched = false
      for _, option in ipairs(expected) do
        if vehicleInfo[key] == option or (type(aggregate) == "table" and aggregate[option]) then
          matched = true
          break
        end
      end
      if not matched then return false end
    end
  end
  return true
end

local function matchesFilter(vehicleInfo, filter)
  if type(filter) ~= "table" then return false end
  if filter.whiteList and not matchesFiltersList(vehicleInfo, filter.whiteList) then return false end
  if filter.blackList and matchesFiltersList(vehicleInfo, filter.blackList) then return false end
  return true
end

local function matchesFilterConfig(vehicleInfo, config)
  local base = config.filter or {}
  if not matchesFilter(vehicleInfo, base) then return false end
  if type(config.subFilters) ~= "table" or tableIsEmpty(config.subFilters) then return true end
  for _, subFilter in ipairs(config.subFilters) do
    local merged = deepcopy(base)
    tableMergeRecursive(merged, subFilter)
    if matchesFilter(vehicleInfo, merged) then return true end
  end
  return false
end

local function appendMetadataStrings(value, output, depth)
  if depth > 3 then return end
  if type(value) == "string" then
    output[#output + 1] = value:lower()
  elseif type(value) == "table" then
    for key, child in pairs(value) do
      if type(key) == "string" then output[#output + 1] = key:lower() end
      appendMetadataStrings(child, output, depth + 1)
    end
  end
end

local function isElectricOrHybrid(vehicleInfo)
  local values = {}
  for _, key in ipairs({"Fuel Type", "FuelType", "fuelType", "Powertrain", "Propulsion"}) do
    appendMetadataStrings(vehicleInfo and vehicleInfo[key], values, 0)
    appendMetadataStrings(vehicleInfo and vehicleInfo.aggregates and vehicleInfo.aggregates[key], values, 0)
  end
  local text = table.concat(values, " ")
  return text:find("electric", 1, true) ~= nil or text:find("hybrid", 1, true) ~= nil
end

local MISSION_STARTING_CONFIG_TYPES = {
  roleplay = true,
  police = true
}

local function configTypeStartsMissions(vehicleInfo)
  if type(vehicleInfo) ~= "table" then return false end
  local values = {}
  appendMetadataStrings(vehicleInfo["Config Type"], values, 0)
  appendMetadataStrings(vehicleInfo.configType, values, 0)
  appendMetadataStrings(vehicleInfo.aggregates and vehicleInfo.aggregates["Config Type"], values, 0)
  for _, text in ipairs(values) do
    if MISSION_STARTING_CONFIG_TYPES[text] then return true end
  end
  return false
end

local function filterUnlocked(filter, level)
  if level >= (filter.skillUnlockLevel or 50) then return true end
  local flag = filter.skillUnlockFlag
  return flag and career_modules_unlockFlags and career_modules_unlockFlags.getFlag
    and career_modules_unlockFlags.getFlag(flag) == true
end

local function buildVehiclePool()
  local level = getSkillLevel()
  if vehiclePoolCache and vehiclePoolSkillLevel == level then return vehiclePoolCache end
  vehiclePoolSkillLevel = level
  vehiclePoolCache = {}
  local filters = loadFilters()
  local allVehicles = configListGenerator.getEligibleVehicles(false, false) or {}
  for _, vehicleInfo in ipairs(allVehicles) do
    if not isElectricOrHybrid(vehicleInfo) and not configTypeStartsMissions(vehicleInfo) then
      for _, filter in ipairs(filters) do
        if filterUnlocked(filter, level) and matchesFilterConfig(vehicleInfo, filter) then
          local candidate = deepcopy(vehicleInfo)
          candidate.recoveryTag = filter.unlockTag
          candidate.recoveryTierLabel = filter.tierLabel
          candidate.recoveryPayMultiplier = filter.payMultiplier
          candidate.recoveryBaseXp = filter.baseXp
          vehiclePoolCache[#vehiclePoolCache + 1] = candidate
          break
        end
      end
    end
  end
  return vehiclePoolCache
end

local function getSpotMinLevel(spot)
  local custom = spot and spot.customFields
  local value = custom and custom.values and tonumber(custom.values.minLevel)
  return value and math.max(1, math.floor(value)) or 1
end

local function spotHasTag(spot, tag)
  local tags = spot and spot.customFields and spot.customFields.tags
  if type(tags) ~= "table" then return false end
  local wanted = string.lower(tostring(tag))
  for key, value in pairs(tags) do
    if type(key) == "string" and string.lower(key) == wanted and value ~= false then return true end
    if type(value) == "string" and string.lower(value) == wanted then return true end
  end
  return false
end

local function spotAllowsRewardType(spot, rewardType)
  -- Map authors can reserve special finds for vehicle-reward contracts without
  -- changing the behavior of existing, untagged recovery spots.
  return rewardType == "vehicle" or not spotHasTag(spot, "keepItOnly")
end

-- Site names are internal persistence keys only. Map authors can leave the
-- editor-generated name alone (or leave it blank); contracts never expose it.
local function getSpotKey(spot)
  local name = spot and type(spot.name) == "string" and spot.name:match("^%s*(.-)%s*$") or ""
  if name ~= "" then return name end
  local pos = spot and spot.pos
  if not pos then return nil end
  return string.format("recovery@%.3f,%.3f,%.3f", pos.x or pos[1] or 0, pos.y or pos[2] or 0, pos.z or pos[3] or 0)
end

local function loadRecoverySites(force)
  local mapId = getCurrentLevelIdentifier()
  if not mapId then return nil end
  if not force and sitesCache and sitesCacheMap == mapId then return sitesCache end
  sitesCache, sitesCacheMap = nil, mapId
  local sitePath = sitesManager.getCurrentLevelSitesFileByName(SITES_NAME)
  if not sitePath then return nil end
  sitesCache = sitesManager.loadSites(sitePath, force == true, true)
  return sitesCache
end

local function reservedSpotNames(mapId)
  local used = {}
  if mapId == currentMap then
    for _, offer in ipairs(availableOffers) do used[offer.spotName] = true end
  end
  local mapState = getMapState(mapId)
  for _, job in ipairs(mapState and mapState.jobs or {}) do used[job.spotName] = true end
  return used
end

local function safeBoundingBoxDimensions(vehicleInfo)
  local box = type(vehicleInfo) == "table" and vehicleInfo.BoundingBox
  local dimensions = type(box) == "table" and box[2]
  if type(dimensions) ~= "table" then return nil end
  local x, y, z = tonumber(dimensions[1]), tonumber(dimensions[2]), tonumber(dimensions[3])
  if not x or not y or not z then return nil end
  return x, y, z
end

local function vehicleFitsSpot(vehicleInfo, spot)
  local x, y, z = safeBoundingBoxDimensions(vehicleInfo)
  if not x then return true end
  if spot and spot.boxFits then
    local ok, fits = pcall(function() return spot:boxFits(x, y, z) end)
    if ok then return fits == true end
  end
  local scale = spot and spot.scl
  if not scale then return true end
  return x <= (tonumber(scale.x) or tonumber(scale[1]) or x) * 0.9
    and y <= (tonumber(scale.y) or tonumber(scale[2]) or y) * 0.9
    and z <= (tonumber(scale.z) or tonumber(scale[3]) or z) * 0.9
end

local function configPopulation(vehicleInfo)
  return math.max(tonumber(vehicleInfo and vehicleInfo.adjustedPopulation) or tonumber(vehicleInfo and vehicleInfo.Population) or 1, 0)
end

local function chooseWeighted(candidates)
  if #candidates == 0 then return nil end

  local byModel = {}
  local modelKeys = {}
  for _, candidate in ipairs(candidates) do
    local modelKey = candidate.model_key or candidate.model or candidate.key or "_"
    local bucket = byModel[modelKey]
    if not bucket then
      bucket = {}
      byModel[modelKey] = bucket
      modelKeys[#modelKeys + 1] = modelKey
    end
    bucket[#bucket + 1] = candidate
  end

  local configs = byModel[modelKeys[math.random(#modelKeys)]]
  if #configs == 1 then return configs[1] end

  local total = 0
  for _, candidate in ipairs(configs) do
    candidate._recoveryWeight = configPopulation(candidate)
    total = total + candidate._recoveryWeight
  end
  if total <= 0 then return configs[math.random(#configs)] end
  local roll, running = math.random() * total, 0
  for _, candidate in ipairs(configs) do
    running = running + candidate._recoveryWeight
    if running >= roll then return candidate end
  end
  return configs[#configs]
end

local function isTrailerInfo(vehicleInfo)
  local vehicleType = tostring(vehicleInfo and vehicleInfo.Type or ""):lower()
  return vehicleType == "trailer" or tostring(vehicleInfo and vehicleInfo.recoveryTag or "") == "recoveryTrailer"
end

local function rollCondition(vehicleInfo)
  if isTrailerInfo(vehicleInfo) then
    return "complete", 0
  end
  if math.random(100) <= 70 then return "complete", 0 end
  return "brokenEngine", 0
end

local function randomMileageMeters(year)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local age = math.max(0, currentYear - (tonumber(year) or currentYear))
  local ageFactor = math.min(1, age / 30)
  local centerMiles = MIN_TARGET_MILES + (MAX_TARGET_MILES - MIN_TARGET_MILES) * ageFactor
  local spreadMiles = 25000
  local minMiles = math.max(MIN_TARGET_MILES, math.floor(centerMiles - spreadMiles))
  local maxMiles = math.min(MAX_TARGET_MILES, math.ceil(centerMiles + spreadMiles))
  local miles = math.random(minMiles, math.max(minMiles, maxMiles))
  return math.floor(miles * MILES_TO_METERS + 0.5)
end

local function offerVehicleValue(vehicleInfo)
  local year = tonumber(vehicleInfo.year) or 2023
  local mileage = tonumber(vehicleInfo.Mileage) or 0
  local baseValue = tonumber(vehicleInfo.Value) or 1000
  if career_modules_valueCalculator and career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue then
    return career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
      catalogBaseValue = baseValue,
      mileageMeters = mileage,
      age = 2025 - year,
      modelName = vehicleInfo.model_key,
      configKey = vehicleInfo.key,
      logContext = LOG_TAG,
      applyVehicleBuyMarket = false
    }) or baseValue
  end
  return baseValue
end

local function nextContractId(prefix)
  local id = string.format("%s-%s-%d", prefix or "recovery", tostring(currentMap or "map"), state.nextId or 1)
  state.nextId = (state.nextId or 1) + 1
  return id
end

local function activeCount(mapId)
  local mapState = getMapState(mapId)
  return #(mapState and mapState.jobs or {})
end

local function offerCount()
  return #availableOffers
end

local function getPlayerPosition()
  local player = be and be:getPlayerVehicle(0)
  return player and player:getPosition() or nil
end

local function getOwnedRecoveryYards()
  local result = {}
  local mapId = getCurrentLevelIdentifier()
  if not mapId or not freeroam_facilities then return result end
  local facilities = freeroam_facilities.getFacilities(mapId)
  for _, garage in ipairs(facilities and facilities.garages or {}) do
    if garage.isRecoveryYard == true and garage.recoveryDropoffSpotName
        and career_modules_garageManager and career_modules_garageManager.isPurchasedGarage
        and career_modules_garageManager.isPurchasedGarage(garage.id) then
      local chosen
      for _, spot in ipairs(freeroam_facilities.getParkingSpotsForFacility(garage) or {}) do
        if spot.name == garage.recoveryDropoffSpotName then
          chosen = spot
          break
        end
      end
      if not chosen then
        local facilitySitesPath = sitesManager.getCurrentLevelSitesFileByName("facilities")
        local facilitySites = facilitySitesPath and sitesManager.loadSites(facilitySitesPath, false, true)
        chosen = facilitySites and facilitySites.parkingSpots and facilitySites.parkingSpots.byName
          and facilitySites.parkingSpots.byName[garage.recoveryDropoffSpotName]
      end
      if chosen and chosen.pos then
        result[#result + 1] = {
          id = garage.id,
          name = translateLanguage and translateLanguage(garage.name, garage.name, true) or garage.name,
          spotName = garage.recoveryDropoffSpotName,
          spot = chosen
        }
      end
    end
  end
  table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return result
end

local function getYardDropoffZones(yardId)
  if not yardId then return nil end
  if dropoffZonesByYardId[yardId] ~= nil then return dropoffZonesByYardId[yardId] end
  local garage = freeroam_facilities.getFacilityIfExists("garage", yardId)
  dropoffZonesByYardId[yardId] = (garage and freeroam_facilities.getZonesForFacility(garage)) or {}
  return dropoffZonesByYardId[yardId]
end

local function isInYardDropoff(job, vehiclePos)
  if not job or not vehiclePos then return false end
  local zones = getYardDropoffZones(job.yardId)
  if zones and #zones > 0 then
    for _, zone in ipairs(zones) do
      if zone.containsPoint2D and zone:containsPoint2D(vehiclePos) then
        return true
      end
    end
    return false
  end
  local destination = arrayToVec3(job.deliveryPos)
  return destination and vehiclePos:distance(destination) <= DELIVERY_RADIUS
end

local function economyMultiplier()
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    return tonumber((career_economyAdjuster.getSectionMultiplier("offroadRecovery"))) or 1
  end
  return 1
end

local function routeDistance(fromPos, toPos)
  if not fromPos or not toPos then return 0 end
  local straight = fromPos:distance(toPos)
  local ok, result = pcall(function()
    local planner = routeFactory()
    planner:setRouteParams(nil, 1e3)
    planner:setupPath(fromPos, toPos)
    local distance = planner.path and planner.path[1] and planner.path[1].distToTarget or planner.distance
    planner:clear()
    return tonumber(distance)
  end)
  return ok and result and result > 0 and result or straight
end

local function difficultyRewardScale()
  local economy = economyMultiplier()
  local difficultyMult = 1
  local modeName
  if economy == 1
      and career_modules_difficultyMode
      and career_modules_difficultyMode.isDifficultyActive
      and career_modules_difficultyMode.isDifficultyActive()
      and career_modules_difficultyMode.getRewardMultiplier then
    difficultyMult = tonumber((career_modules_difficultyMode.getRewardMultiplier())) or 1
    if career_modules_difficultyMode.getMode then
      modeName = tostring(career_modules_difficultyMode.getMode() or "")
    end
  end
  return economy * difficultyMult, economy, difficultyMult, modeName
end

-- Returns cash, routeDistanceM, breakdown lines for UI / tasklist.
local function fixedCashQuote(offer, yard)
  local distance = routeDistance(arrayToVec3(offer.targetPos), yard.spot.pos)
  local skillLevel = getSkillLevel()
  local skillBonus = getPayoutBonus(skillLevel)
  local payMult = tonumber(offer.payMultiplier) or 1
  local tierLabel = offer.tierLabel or "Recovery"
  local foundation = math.floor((((5 * math.sqrt(math.max(offer.vehicleValue or 1000, 1))) + distance * 2) / 4) / 15)
  local afterBase = foundation + 500
  local afterTier = afterBase * payMult * 1.1
  local afterSkill = afterTier * (1 + skillBonus)
  local scale, economy, difficultyMult, modeName = difficultyRewardScale()
  local payout = afterSkill * scale
  local cash = math.max(0, math.floor(payout + 0.5))

  local breakdown = {
    {
      label = "Base",
      detail = string.format("value + %.1f km route", (distance or 0) / 1000),
      money = afterBase
    }
  }
  if payMult ~= 1 then
    breakdown[#breakdown + 1] = {
      label = string.format("%s tier", tierLabel),
      detail = string.format("×%.2f", payMult)
    }
  else
    breakdown[#breakdown + 1] = {
      label = string.format("%s tier", tierLabel),
      detail = "×1.00"
    }
  end
  breakdown[#breakdown + 1] = {label = "Contract rate", detail = "×1.10"}
  breakdown[#breakdown + 1] = {
    label = string.format("Recovery L%d skill", skillLevel),
    detail = string.format("%+d%%", math.floor(skillBonus * 100 + 0.5))
  }
  if scale ~= 1 then
    local scaleLabel = "Economy adjust"
    if modeName and modeName ~= "" and modeName ~= "normal" then
      scaleLabel = string.format("Difficulty (%s)", modeName)
    elseif economy ~= 1 then
      scaleLabel = "Economy adjust"
    end
    breakdown[#breakdown + 1] = {
      label = scaleLabel,
      detail = string.format("×%.2f", scale)
    }
  end
  breakdown[#breakdown + 1] = {label = "Quoted cash", money = cash, isTotal = true}
  return cash, distance, breakdown
end

local function formatBreakdownLine(line)
  if not line then return "" end
  if line.xp ~= nil then
    return string.format("%s: +%d", line.label or "XP", tonumber(line.xp) or 0)
  end
  if line.money ~= nil and line.detail then
    return string.format("%s (%s): $%s", line.label or "", line.detail, tostring(math.floor(tonumber(line.money) or 0)))
  end
  if line.money ~= nil then
    local amount = math.floor(tonumber(line.money) or 0)
    if amount < 0 then
      return string.format("%s: −$%s", line.label or "", tostring(math.abs(amount)))
    end
    return string.format("%s: $%s", line.label or "", tostring(amount))
  end
  if line.detail then
    return string.format("%s: %s", line.label or "", line.detail)
  end
  return tostring(line.label or "")
end

local function showCompletionTasklist(breakdown, header)
  guihooks.trigger("ClearTasklist")
  guihooks.trigger("SetTasklistHeader", {label = header or "Recovery Complete"})
  for index, line in ipairs(breakdown or {}) do
    guihooks.trigger("SetTasklistTask", {
      id = "offroadRecovery_complete_" .. index,
      label = formatBreakdownLine(line),
      done = line.isTotal == true,
      active = true,
      type = "message",
      clear = false
    })
  end
  clearTasklistTimer = TASKLIST_CLEAR_SECONDS
end

local function openRecoveryApp()
  local function navigate()
    if gameplay_phone and gameplay_phone.openRoute then
      gameplay_phone.openRoute("phone-offroad-recovery")
    elseif extensions and extensions.ui_router then
      extensions.ui_router.navigate("phone-offroad-recovery")
    end
  end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(jobHandle)
      jobHandle.sleep(0.2)
      navigate()
    end)
  else
    navigate()
  end
end

local function buildCompletionBreakdown(job, finalCash, finalXp, penalty)
  local lines = {}
  if job.rewardType == "cash" then
    if type(job.payBreakdown) == "table" then
      for _, line in ipairs(job.payBreakdown) do
        lines[#lines + 1] = deepcopy(line)
      end
    else
      lines[#lines + 1] = {
        label = "Quoted cash",
        money = math.max(0, math.floor(tonumber(job.cashReward) or 0)),
        isTotal = true
      }
    end
    local quoted = math.max(0, math.floor(tonumber(job.cashReward) or 0))
    local paid = math.max(0, math.floor(tonumber(finalCash) or 0))
    local penaltyPercent = math.floor((tonumber(penalty) or 0) * 100 + 0.5)
    if penaltyPercent > 0 then
      lines[#lines + 1] = {
        label = "Damage penalty",
        detail = string.format("−%d%%", penaltyPercent),
        money = paid - quoted,
        isPenalty = true
      }
    end
    lines[#lines + 1] = {label = "Paid", money = paid, isTotal = true}
  else
    lines[#lines + 1] = {label = "Reward", detail = "Vehicle awarded", isTotal = true}
    local penaltyPercent = math.floor((tonumber(penalty) or 0) * 100 + 0.5)
    if penaltyPercent > 0 then
      lines[#lines + 1] = {
        label = "Damage penalty",
        detail = string.format("−%d%% XP", penaltyPercent),
        isPenalty = true
      }
    end
  end
  lines[#lines + 1] = {label = "Recovery XP", xp = math.max(0, math.floor(tonumber(finalXp) or 0))}
  return lines
end

local function fixedSkillXp(offer, distance)
  return math.max(1, math.floor((5 + (tonumber(offer.baseXp) or 0) + math.floor((distance or 0) / 2000 + 0.5)) * 4 + 0.5))
end

local function pickVehicleAndSpot(rewardType)
  local data = loadRecoverySites()
  local spots = data and data.parkingSpots and data.parkingSpots.objects
  if not spots then return nil end
  local level = getSkillLevel()
  local used = reservedSpotNames(currentMap)
  local eligibleSpots = {}
  for _, spot in pairs(spots) do
    local spotKey = getSpotKey(spot)
    if spot.pos and spotKey and not used[spotKey] and level >= getSpotMinLevel(spot)
        and spotAllowsRewardType(spot, rewardType) then
      eligibleSpots[#eligibleSpots + 1] = spot
    end
  end
  for i = #eligibleSpots, 2, -1 do
    local j = math.random(i)
    eligibleSpots[i], eligibleSpots[j] = eligibleSpots[j], eligibleSpots[i]
  end
  local pool = buildVehiclePool()
  for _, spot in ipairs(eligibleSpots) do
    local fitting = {}
    for _, candidate in ipairs(pool) do
      if vehicleFitsSpot(candidate, spot) then fitting[#fitting + 1] = candidate end
    end
    local vehicleInfo = chooseWeighted(fitting)
    if vehicleInfo then return deepcopy(vehicleInfo), spot end
  end
end

local function generateOffer()
  if offerCount() >= MAX_OFFERS or not currentMap then return nil end
  local level = getSkillLevel()
  local rewardType = level >= 10 and math.random(100) <= level and "vehicle" or "cash"
  local vehicleInfo, spot = pickVehicleAndSpot(rewardType)
  if not vehicleInfo or not spot then return nil end
  local years = vehicleInfo.Years or (vehicleInfo.aggregates and vehicleInfo.aggregates.Years)
  if type(years) == "table" and tonumber(years.min) and tonumber(years.max) then
    vehicleInfo.year = math.random(tonumber(years.min), tonumber(years.max))
  else
    vehicleInfo.year = 2023
  end
  vehicleInfo.Mileage = randomMileageMeters(vehicleInfo.year)
  local condition, missingWheelCount = rollCondition(vehicleInfo)
  local offer = {
    id = nextContractId("offer"),
    createdAt = simMinutes,
    expiresAt = simMinutes + OFFER_TTL_MINUTES,
    spotName = getSpotKey(spot),
    targetPos = toVec3Array(spot.pos),
    targetRot = toQuatArray(spot.rot or quat(0, 0, 0, 1)),
    minLevel = getSpotMinLevel(spot),
    model = vehicleInfo.model_key,
    configKey = vehicleInfo.key,
    brand = vehicleInfo.Brand or vehicleInfo.model_key or "Unknown",
    name = vehicleInfo.Name or vehicleInfo.key or "Vehicle",
    year = vehicleInfo.year,
    mileage = vehicleInfo.Mileage,
    vehicleType = vehicleInfo.Type,
    recoveryTag = vehicleInfo.recoveryTag,
    tierLabel = vehicleInfo.recoveryTierLabel,
    payMultiplier = vehicleInfo.recoveryPayMultiplier,
    baseXp = vehicleInfo.recoveryBaseXp,
    vehicleValue = offerVehicleValue(vehicleInfo),
    rewardType = rewardType,
    condition = condition,
    missingWheelCount = missingWheelCount,
    wheelSeed = math.random(1000000)
  }
  if offer.rewardType == "cash" then
    local yards = getOwnedRecoveryYards()
    if #yards == 1 then offer.cashReward = select(1, fixedCashQuote(offer, yards[1])) end
  end
  availableOffers[#availableOffers + 1] = offer
  extensions.hook("onOffroadRecoveryOfferGenerated", offer.id)
  return offer
end

local function serializableState()
  local result = deepcopy(state)
  for _, mapState in pairs(result.maps or {}) do
    for _, job in ipairs(mapState.jobs or {}) do
      job.vehicleId = nil
      job.completing = nil
      job.spawnPending = nil
      if job.status == "active" or job.status == "spawning" then job.status = "paused" end
    end
  end
  return result
end

local function saveStateToPath(savePath)
  if not savePath then return end
  ensureSaveDirectories(savePath)
  career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_FILE, serializableState(), true)
end

local function saveState()
  saveStateToPath(currentSavePath())
end

local function loadState()
  local savePath = currentSavePath()
  local loaded = savePath and jsonReadFile(savePath .. SAVE_FILE)
  if type(loaded) == "table" and type(loaded.maps) == "table" then
    state = loaded
    state.version = 1
    state.nextId = tonumber(state.nextId) or 1
  else
    state = {version = 1, maps = {}, nextId = 1}
  end
end

local function capturePose(job)
  local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then return false end
  job.targetPos = toVec3Array(vehicle:getPosition())
  job.targetRot = toQuatArray(quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation()))
  return true
end

local function captureEnergy(job, callback)
  local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    if callback then callback(false) end
    return
  end
  core_vehicleBridge.requestValue(vehicle, function(response)
    local tanks = response and (response.result or response)
    if type(tanks) ~= "table" then
      if callback then callback(false) end
      return
    end
    job.energyStorage = {}
    for _, tank in ipairs(tanks[1] or tanks) do
      if tank.name then
        job.energyStorage[#job.energyStorage + 1] = {
          name = tank.name,
          energyType = tank.energyType,
          currentEnergy = tonumber(tank.currentEnergy) or 0
        }
      end
    end
    if callback then callback(true) end
  end, "energyStorage")
end

local function saveDamageSnapshot(job, savePath, callbackCode)
  local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
  local pathName = job and damageFilePath(job.id, savePath)
  if not vehicle or not pathName then return false end
  local command = string.format(
    "extensions.load('individualRepair'); if individualRepair then individualRepair.saveDamageData(%q) end",
    pathName:gsub("\\", "/"))
  if callbackCode then
    command = command .. string.format("; obj:queueGameEngineLua(%q)", callbackCode)
  end
  vehicle:queueLuaCommand(command)
  return true
end

local function updateJobSnapshotFromInventory(job)
  if not job or not job.inventoryId or not career_modules_inventory then return false end
  local record = career_modules_inventory.getVehicles()[job.inventoryId]
  if not record then return false end
  record.year = job.year or record.year
  record.mileage = math.max(tonumber(record.mileage) or 0, tonumber(job.mileage) or 0)
  job.vehicleSnapshot = job.vehicleSnapshot or {}
  job.vehicleSnapshot.model = job.vehicleSnapshot.model or record.model
  job.vehicleSnapshot.config = job.vehicleSnapshot.config or deepcopy(record.config)
  job.vehicleSnapshot.partConditions = deepcopy(record.partConditions or {})
  return true
end

local function captureExitState(job, savePath)
  local vehicle = job and job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then return end
  capturePose(job)
  captureEnergy(job, function() saveStateToPath(savePath) end)
  saveDamageSnapshot(job, savePath)
  if job.inventoryId and career_modules_inventory then
    career_modules_inventory.updatePartConditions(job.vehicleId, job.inventoryId, function()
      updateJobSnapshotFromInventory(job)
      saveStateToPath(savePath)
    end)
  end
end

local function hasSpawnedCurrentMapJob()
  if not currentMap then return false end
  for _, job in ipairs(getMapState(currentMap).jobs or {}) do
    if job.status == "active" and job.vehicleId and getObjectByID(job.vehicleId) then return true end
  end
  return false
end

local function stageDamageSnapshots(oldSavePath, newSavePath)
  if not newSavePath then return end
  ensureSaveDirectories(newSavePath)
  if oldSavePath == newSavePath then return end

  local destinationDir = newSavePath .. DAMAGE_DIR
  for _, filePath in ipairs(FS:findFiles(destinationDir, "*.json", 0, false, false) or {}) do
    local ok, err = pcall(FS.removeFile, FS, filePath)
    if not ok then log("W", LOG_TAG, "Could not remove stale recovery snapshot: " .. tostring(err)) end
  end

  if not oldSavePath then return end
  for _, mapState in pairs(state.maps or {}) do
    for _, job in ipairs(mapState.jobs or {}) do
      local source = damageFilePath(job.id, oldSavePath)
      local destination = damageFilePath(job.id, newSavePath)
      if source and destination and FS:fileExists(source) then
        local ok, result = pcall(FS.copyFile, FS, source, destination)
        if not ok or result == false then
          log("W", LOG_TAG, "Could not carry recovery snapshot forward for " .. tostring(job.id))
        end
      end
    end
  end
end

local function finishCareerSave(timedOut)
  local pending = pendingCareerSave
  if not pending then return end
  if not timedOut then
    if not pending.inventoryReady then return end
    for _, entry in pairs(pending.jobs) do
      if not entry.energyDone or not entry.damageDone then return end
    end
  end

  if timedOut then
    local incomplete = {}
    if not pending.inventoryReady then incomplete[#incomplete + 1] = "inventory" end
    for _, entry in pairs(pending.jobs) do
      if not entry.energyDone then incomplete[#incomplete + 1] = tostring(entry.job.id) .. ":energy" end
      if not entry.damageDone then incomplete[#incomplete + 1] = tostring(entry.job.id) .. ":damage" end
    end
    log("W", LOG_TAG, "Recovery save timed out; retaining the last complete data for " .. table.concat(incomplete, ", "))
  end

  saveStateToPath(pending.savePath)
  pendingCareerSave = nil
  saveRegistered = false
  local generation = saveGenerationToken
  saveGenerationToken = nil
  if career_saveSystem and career_saveSystem.asyncSaveExtensionFinished then
    career_saveSystem.asyncSaveExtensionFinished(ASYNC_SAVE_EXTENSION, generation)
  end
end

local function markCareerSaveEnergyDone(token, jobId)
  local pending = pendingCareerSave
  if not pending or pending.token ~= token then return end
  local entry = pending.jobs[tostring(jobId)]
  if not entry then return end
  entry.energyDone = true
  finishCareerSave(false)
end

local function beginCareerSave(savePath)
  nextSaveToken = nextSaveToken + 1
  local token = "save-" .. tostring(nextSaveToken)
  local oldSavePath = currentSavePath()
  stageDamageSnapshots(oldSavePath, savePath)
  pendingCareerSave = {
    token = token,
    savePath = savePath,
    oldSavePath = oldSavePath,
    elapsed = 0,
    inventoryReady = false,
    jobs = {}
  }

  for _, job in ipairs(currentMap and getMapState(currentMap).jobs or {}) do
    local vehicle = job.status == "active" and job.vehicleId and getObjectByID(job.vehicleId)
    if vehicle then
      capturePose(job)
      local entry = {job = job, energyDone = false, damageDone = false}
      pendingCareerSave.jobs[tostring(job.id)] = entry
      captureEnergy(job, function() markCareerSaveEnergyDone(token, job.id) end)
      local callbackCode = string.format("gameplay_offroadRecovery.onDamageSnapshotSaved(%q, %q)", token, tostring(job.id))
      if not saveDamageSnapshot(job, savePath, callbackCode) then entry.damageDone = true end
    end
  end

  if tableCount(pendingCareerSave.jobs) == 0 then
    pendingCareerSave.inventoryReady = true
    finishCareerSave(false)
  end
end

function M.onDamageSnapshotSaved(token, jobId)
  local pending = pendingCareerSave
  if not pending or pending.token ~= token then return end
  local entry = pending.jobs[tostring(jobId)]
  if not entry then return end
  entry.damageDone = true
  finishCareerSave(false)
end

local function waitForEnergyUpdate(vehicle, callback)
  if not callback then return end
  if not vehicle then
    callback()
    return
  end
  -- executeAction is asynchronous. Waiting for a bridge response keeps the
  -- next snapshot from reading and saving the vehicle's old full-tank value.
  core_vehicleBridge.requestValue(vehicle, function() callback() end, "ping")
end

local function setStoredEnergy(job, vehicle, callback)
  if not vehicle or type(job.energyStorage) ~= "table" then
    if callback then callback() end
    return
  end
  for _, tank in ipairs(job.energyStorage) do
    if tank.name then
      core_vehicleBridge.executeAction(vehicle, "setEnergyStorageEnergy", tank.name, tonumber(tank.currentEnergy) or 0)
    end
  end
  waitForEnergyUpdate(vehicle, callback)
end

-- Maneuvering fuel only: enough to creep onto a trailer. 1% of tank, capped at 1 L.
local function setOneLiter(job, vehicle, callback)
  core_vehicleBridge.requestValue(vehicle, function(response)
    local tanks = response and (response.result or response)
    local allTanks = type(tanks) == "table" and (tanks[1] or tanks) or {}
    local factors = {gasoline = 31.125, diesel = 36.112, kerosine = 34.4}
    local assigned = false
    job.energyStorage = {}
    for _, tank in ipairs(allTanks) do
      local energy = 0
      local factor = factors[tank.energyType]
      if factor and not assigned then
        local oneLiterJ = factor * 1000000
        local maxEnergy = tonumber(tank.maxEnergy) or 0
        energy = maxEnergy > 0 and math.min(maxEnergy * 0.01, oneLiterJ) or oneLiterJ
        assigned = true
      end
      if tank.name then
        core_vehicleBridge.executeAction(vehicle, "setEnergyStorageEnergy", tank.name, energy)
        job.energyStorage[#job.energyStorage + 1] = {name = tank.name, energyType = tank.energyType, currentEnergy = energy}
      end
    end
    waitForEnergyUpdate(vehicle, callback)
  end, "energyStorage")
end

local function attachTemporaryInventory(job, vehicle, callback)
  if not vehicle or not career_modules_inventory then
    if callback then callback(false) end
    return
  end
  job.inventoryId = job.inventoryId or ("offroadRecovery:" .. job.id)
  local inventoryId = career_modules_inventory.addVehicle(vehicle:getID(), job.inventoryId, {
    owned = false,
    skipPartConditionInit = true
  })
  if not inventoryId then
    if callback then callback(false) end
    return
  end
  local record = career_modules_inventory.getVehicles()[inventoryId]
  if record then
    record.offroadRecoveryContract = true
    record.offroadRecoveryJobId = job.id
    record.loanType = nil
    record.year = job.year
    record.mileage = tonumber(job.mileage) or record.mileage or 0
    if job.vehicleSnapshot and job.vehicleSnapshot.partConditions then
      record.partConditions = deepcopy(job.vehicleSnapshot.partConditions)
    end
  end
  job.inventoryId = inventoryId
  runtimeByVehicleId[vehicle:getID()] = job.id
  if callback then callback(true) end
end

local function finishNewTarget(job)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    job.status = "missing"
    job.spawnPending = nil
    return
  end
  setOneLiter(job, vehicle, function()
    attachTemporaryInventory(job, vehicle, function(ok)
      job.spawnPending = nil
      if not ok then
        job.status = "missing"
        return
      end
      career_modules_inventory.updatePartConditions(job.vehicleId, job.inventoryId, function()
        local record = career_modules_inventory.getVehicles()[job.inventoryId]
        if record then
          job.baselineConditions = deepcopy(record.partConditions or {})
          job.vehicleSnapshot = {
            model = record.model,
            config = deepcopy(record.config),
            partConditions = deepcopy(record.partConditions)
          }
        end
        job.status = "active"
        capturePose(job)
        saveState()
        M.requestState()
      end)
    end)
  end)
end

local function finishRestoredTarget(job)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    job.status = "missing"
    job.spawnPending = nil
    return
  end
  attachTemporaryInventory(job, vehicle, function(ok)
    job.spawnPending = nil
    if not ok then
      job.status = "missing"
      return
    end
    setStoredEnergy(job, vehicle, function()
      local pathName = damageFilePath(job.id)
      if pathName and FS:fileExists(pathName) then
        vehicle:queueLuaCommand(string.format(
          "extensions.load('individualRepair'); if individualRepair then individualRepair.loadDamageData(%q) end",
          pathName:gsub("\\", "/")
        ))
      end
      job.status = "active"
      M.requestState()
    end)
  end)
end

local function initialConditionCommand(job, vehId)
  local conditionKind = job.condition == "brokenEngine" and "engine" or "normal"
  local mileage = math.max(0, tonumber(job.mileage) or 0)
  return string.format([[
    local conditionKind = %q
    local mileage = %.0f
    local parts = {}
    for partPath, partName in pairs(v.data.activeParts or {}) do
      -- Match the part itself, not its full slot path. Drivetrain parts such as
      -- transmissions and differentials often live below an engine slot and
      -- would otherwise be destroyed along with the engine.
      local key = string.lower(tostring(partName))
      local integrity = 1
      if conditionKind == "engine" and string.find(key, "engine", 1, true)
          and not string.find(key, "mount", 1, true) then
        integrity = 0
      end
      parts[partPath] = {odometer = mileage, integrityValue = integrity, visualValue = 1}
    end
    partCondition.initConditions(parts, mileage, 1, 1)
    obj:queueGameEngineLua(%q)
  ]], conditionKind, mileage,
    string.format("gameplay_offroadRecovery.onInitialConditionApplied(%q, %d)", job.id, vehId))
end

local function resolveConfigPath(model, config)
  if type(config) ~= "string" or config == "" then return nil end
  local vehicleDir = "/vehicles/" .. tostring(model) .. "/"
  local configPath = config
  if not configPath:find("/", 1, true) and not configPath:find("\\", 1, true) then
    configPath = vehicleDir .. configPath
  elseif configPath:sub(1, 1) ~= "/" then
    configPath = "/" .. configPath:gsub("\\", "/")
  end
  if configPath:sub(-3):lower() ~= ".pc" then configPath = configPath .. ".pc" end
  return configPath
end

local function isWheelPartSlot(slotName)
  local key = tostring(slotName or ""):lower()
  if key == "" or key:find("wheeldata", 1, true) or key:find("wheelhub", 1, true)
      or key:find("wheelie", 1, true) or key:find("wheelskirt", 1, true) then
    return false
  end
  return key:match("^wheel[_%d]") ~= nil or key:find("_wheel", 1, true) ~= nil
end

local function configWithMissingWheelSlots(job, config)
  local count = math.max(0, math.floor(tonumber(job and job.missingWheelCount) or 0))
  if count == 0 then return config end

  local result
  local configPath
  if type(config) == "table" then
    result = deepcopy(config)
  else
    configPath = resolveConfigPath(job.model, config)
    result = configPath and jsonReadFile(configPath) or nil
  end
  if type(result) ~= "table" or type(result.parts) ~= "table" then
    log("W", LOG_TAG, "Could not prepare missing wheel slots for recovery " .. tostring(job.id))
    return config
  end

  local candidates = {}
  for slotName, partName in pairs(result.parts) do
    if partName ~= nil and partName ~= "" and isWheelPartSlot(slotName) then
      candidates[#candidates + 1] = slotName
    end
  end
  table.sort(candidates)
  if #candidates == 0 then
    log("W", LOG_TAG, "Recovery config has no removable wheel slots: " .. tostring(job.id))
    return result
  end

  local startIndex = ((tonumber(job.wheelSeed) or 1) % #candidates) + 1
  job.missingWheelSlots = {}
  for offset = 0, math.min(count, #candidates) - 1 do
    local slotName = candidates[((startIndex + offset - 1) % #candidates) + 1]
    result.parts[slotName] = ""
    job.missingWheelSlots[#job.missingWheelSlots + 1] = slotName
  end
  if configPath and not result.partConfigFilename then result.partConfigFilename = configPath end
  return result
end

local function withRecoverySpawnFlag(job, config)
  local result
  if type(config) == "table" then
    result = deepcopy(config)
  else
    local configPath = resolveConfigPath(job and job.model, config)
    result = configPath and jsonReadFile(configPath) or nil
    if type(result) ~= "table" then return config end
    if configPath and not result.partConfigFilename then result.partConfigFilename = configPath end
  end
  result.isRecovery = true
  return result
end

local function targetContentAvailable(model, config)
  if type(model) ~= "string" or model == "" then return false end

  -- Avoid core_vehicles.getModel() here. Its first call builds the complete
  -- enabled vehicle cache, while restoring a contract only needs to establish
  -- that this particular vehicle is still mounted.
  local vehicleDir = "/vehicles/" .. model .. "/"
  if not FS:directoryExists(vehicleDir) then return false end
  if not FS:fileExists(vehicleDir .. "info.json") then return false end
  -- Add-on part packs can leave a model directory mounted after the base mod
  -- is disabled. Only root JBeam files define the actual spawnable model.
  local jbeamFiles = FS:findFiles(vehicleDir, "*.jbeam", 0, false, false)
  if type(jbeamFiles) ~= "table" or #jbeamFiles == 0 then return false end

  -- A saved vehicle snapshot contains the parts needed to rebuild the target;
  -- its original .pc may legitimately no longer exist. New jobs still use a
  -- catalog config key, so validate that file before asking the engine to spawn.
  if type(config) == "table" then
    if type(config.partsTree) == "table" and next(config.partsTree) ~= nil then return true end
    if type(config.parts) == "table" and next(config.parts) ~= nil then return true end
    config = config.partConfigFilename
  end
  if type(config) ~= "string" or config == "" then return false end

  local configPath = resolveConfigPath(model, config)
  return FS:fileExists(configPath)
end

local function spawnJobTarget(job, restored)
  if not job or job.spawnPending or job.status == "missing" or currentMap ~= job.mapId then return end
  if job.vehicleId and getObjectByID(job.vehicleId) then return end
  local config = restored and job.vehicleSnapshot and job.vehicleSnapshot.config or job.configKey
  if not targetContentAvailable(job.model, config) then
    job.vehicleId = nil
    job.spawnPending = nil
    job.status = "missing"
    log("W", LOG_TAG, string.format("Recovery target content is unavailable for %s (%s); contract remains abandonable", tostring(job.id), tostring(job.model)))
    saveState()
    M.requestState()
    return false
  end
  if not restored then config = configWithMissingWheelSlots(job, config) end
  config = withRecoverySpawnFlag(job, config)
  job.spawnPending = true
  job.status = "spawning"
  local vehicle = core_vehicles.spawnNewVehicle(job.model, {
    config = config,
    autoEnterVehicle = false,
    pos = arrayToVec3(job.targetPos),
    rot = arrayToQuat(job.targetRot),
    cling = false,
    paint = {baseColor = {math.random(), math.random(), math.random(), 1}, metallic = false},
    electrics = {parkingbrake = 0}
  })
  if not vehicle then
    job.spawnPending = nil
    job.status = "missing"
    M.requestState()
    return
  end
  job.vehicleId = vehicle:getID()
  runtimeByVehicleId[job.vehicleId] = job.id
  if restored and job.vehicleSnapshot and job.vehicleSnapshot.partConditions then
    core_vehicleBridge.executeAction(vehicle, "initPartConditions", job.vehicleSnapshot.partConditions, 0, 1, 1)
    core_vehicleBridge.requestValue(vehicle, function()
      finishRestoredTarget(job)
    end, "ping")
  else
    vehicle:queueLuaCommand(initialConditionCommand(job, vehicle:getID()))
  end
end

function M.onInitialConditionApplied(jobId, vehicleId)
  local job = findJob(jobId)
  if not job or job.vehicleId ~= vehicleId then return end
  core_jobsystem.create(function(jobHandle)
    jobHandle.sleep(0.35)
    finishNewTarget(job)
  end)
end

local function removeOfferAt(index)
  table.remove(availableOffers, index)
  if pendingOfferId and not findOffer(pendingOfferId) then pendingOfferId = nil end
end

local function pickTrackedJobId(mapState)
  local fallback
  for _, candidate in ipairs(mapState and mapState.jobs or {}) do
    if candidate.status ~= "missing" then
      fallback = fallback or candidate.id
      if candidate.phase ~= "delivery" then
        return candidate.id
      end
    end
  end
  return fallback
end

local function removeJobFromState(job)
  local mapState = getMapState(job.mapId)
  for index, candidate in ipairs(mapState.jobs) do
    if candidate.id == job.id then
      table.remove(mapState.jobs, index)
      break
    end
  end
  if mapState.trackedJobId == job.id then
    mapState.trackedJobId = pickTrackedJobId(mapState)
  end
end

-- Re-attach currently coupled nodes at huge strength so a deck-mass delete
-- cannot impulse-break gooseneck/pintle hitches. Restore after settle.
local TEMP_COUPLER_LOCK_CMD = [[
if beamstate and beamstate.attachedCouplers and beamstate.couplerCache then
  for nid, _ in pairs(beamstate.attachedCouplers) do
    local c = beamstate.couplerCache[nid]
    if c and c.cid and not c.couplerWeld then
      local tag = c.couplerTag or c.tag
      if tag then
        obj:attachCoupler(c.cid, tag, 1e12, c.couplerRadius or 0.2, c.couplerLockRadius or 0.025, c.couplerLatchSpeed or 0.3, c.couplerTargets or 0)
      end
    end
  end
end
]]

local TEMP_COUPLER_UNLOCK_CMD = [[
if beamstate and beamstate.attachedCouplers and beamstate.couplerCache then
  for nid, _ in pairs(beamstate.attachedCouplers) do
    local c = beamstate.couplerCache[nid]
    if c and c.cid and not c.couplerWeld then
      local tag = c.couplerTag or c.tag
      if tag then
        obj:attachCoupler(c.cid, tag, c.couplerStrength or 1000000, c.couplerRadius or 0.2, c.couplerLockRadius or 0.025, c.couplerLatchSpeed or 0.3, c.couplerTargets or 0)
      end
    end
  end
end
]]

local function collectHaulerIdsNearTarget(targetVehId)
  local ids = {}
  local seen = {}
  local function add(id)
    if id and id ~= targetVehId and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end

  local function addTrain(rootId)
    if not rootId or rootId == targetVehId then return end
    if overhaul_playerVehicles and overhaul_playerVehicles.fillCouplerGroup then
      local group = {}
      overhaul_playerVehicles.fillCouplerGroup(rootId, group, {resolveLead = true})
      for _, id in ipairs(group) do add(id) end
    else
      add(rootId)
    end
  end

  local playerId = be and be:getPlayerVehicleID(0)
  if playerId and playerId ~= -1 then addTrain(playerId) end

  local target = targetVehId and getObjectByID(targetVehId)
  local tpos = target and target:getPosition()
  if tpos and getAllVehicles then
    for _, veh in ipairs(getAllVehicles()) do
      local id = veh.getID and veh:getID() or (veh.getId and veh:getId())
      if id and id ~= targetVehId then
        local p = veh:getPosition()
        local dx, dy = p.x - tpos.x, p.y - tpos.y
        if (dx * dx + dy * dy) < (25 * 25) then
          addTrain(id)
        end
      end
    end
  end
  return ids
end

local function setHaulerCouplerLock(haulerIds, lock)
  local cmd = lock and TEMP_COUPLER_LOCK_CMD or TEMP_COUPLER_UNLOCK_CMD
  for _, id in ipairs(haulerIds or {}) do
    local obj = getObjectByID(id)
    if obj and obj.queueLuaCommand then
      pcall(function() obj:queueLuaCommand(cmd) end)
    end
  end
end

-- Ghost + lift clear of the deck so contact ends before the object is deleted.
local function clearTargetFromHaulerDeck(vehicle)
  if not vehicle then return end
  pcall(function()
    if vehicle.queueLuaCommand then
      vehicle:queueLuaCommand("obj:setGhostEnabled(true); obj:setVelocity(0,0,0); obj:setAngularVelocity(0,0,0)")
    end
    local pos = vehicle:getPosition()
    local rot = quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation())
    local clearZ = (pos.z or 0) + 60
    if vehicle.setPositionRotation then
      vehicle:setPositionRotation(pos.x, pos.y, clearZ, rot.x, rot.y, rot.z, rot.w)
    elseif vehicle.setPosRot then
      vehicle:setPosRot(pos.x, pos.y, clearZ, rot.x, rot.y, rot.z, rot.w)
    end
  end)
end

local function deleteTemporaryTargetObject(job, vehicleId, inventoryId)
  if inventoryId and career_modules_inventory and career_modules_inventory.getVehicles()[inventoryId] then
    -- The final part state was already captured by the contract. Delete the
    -- temporary world object directly so inventory removal does not start a
    -- second asynchronous damage save against an object it is deleting.
    if career_modules_inventory.removeVehicleObject then
      local ok, err = pcall(career_modules_inventory.removeVehicleObject, inventoryId, true)
      if not ok then log("W", LOG_TAG, "Could not remove abandoned recovery target object: " .. tostring(err)) end
    end
    local ok, err = pcall(career_modules_inventory.removeVehicle, inventoryId)
    if not ok then log("W", LOG_TAG, "Could not remove abandoned recovery inventory record: " .. tostring(err)) end
  elseif vehicleId then
    local vehicle = getObjectByID(vehicleId)
    if vehicle then
      local ok, err = pcall(vehicle.delete, vehicle)
      if not ok then log("W", LOG_TAG, "Could not delete abandoned recovery target: " .. tostring(err)) end
    end
  end
  local pathName = damageFilePath(job and job.id)
  if pathName and FS:fileExists(pathName) then
    local ok, err = pcall(FS.removeFile, FS, pathName)
    if not ok then log("W", LOG_TAG, "Could not remove abandoned recovery damage snapshot: " .. tostring(err)) end
  end
end

-- Soft cleanup: temp-lock hauler couplers, clear deck contact, settle, delete,
-- settle, unlock. Avoids gooseneck/pintle snap when cash payout deletes cargo.
local function cleanupTemporaryTarget(job, callback)
  local vehicleId = job and job.vehicleId
  local inventoryId = job and job.inventoryId
  if vehicleId then runtimeByVehicleId[vehicleId] = nil end

  local vehicle = vehicleId and getObjectByID(vehicleId)
  local haulerIds = collectHaulerIdsNearTarget(vehicleId)

  if job then
    job.vehicleId = nil
    job.inventoryId = nil
  end

  if not vehicleId and not inventoryId then
    if callback then callback() end
    return
  end

  setHaulerCouplerLock(haulerIds, true)
  clearTargetFromHaulerDeck(vehicle)

  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(jobHandle)
      jobHandle.sleep(0.2)
      deleteTemporaryTargetObject(job, vehicleId, inventoryId)
      jobHandle.sleep(0.15)
      setHaulerCouplerLock(haulerIds, false)
      if callback then callback() end
    end)
  else
    deleteTemporaryTargetObject(job, vehicleId, inventoryId)
    setHaulerCouplerLock(haulerIds, false)
    if callback then callback() end
  end
end

local function conditionIntegrity(condition)
  return math.min(1, math.max(0, tonumber(condition and condition.integrityValue) or 1))
end

local function damagePenalty(job, finalConditions)
  local baseline = job.baselineConditions or {}
  local vehicleData = job.vehicleId and core_vehicle_manager.getVehicleData(job.vehicleId)
  local activeParts = vehicleData and vehicleData.vdata and vehicleData.vdata.activeParts or {}
  local activePartsData = vehicleData and vehicleData.vdata and vehicleData.vdata.activePartsData or {}
  local valueLost = 0
  local seen = {}
  for partPath, baseCondition in pairs(baseline) do
    seen[partPath] = true
    local finalCondition = finalConditions and finalConditions[partPath]
    local delta = math.max(0, conditionIntegrity(baseCondition) - (finalCondition and conditionIntegrity(finalCondition) or 0))
    if delta > 0 then
      local partName = activeParts[partPath]
      local partData = partName and activePartsData[partName]
      local partValue = partData and partData.information and tonumber(partData.information.value) or 700
      valueLost = valueLost + partValue * delta
    end
  end
  for partPath, finalCondition in pairs(finalConditions or {}) do
    if not seen[partPath] then
      local delta = math.max(0, 1 - conditionIntegrity(finalCondition))
      if delta > 0 then
        local partName = activeParts[partPath]
        local partData = partName and activePartsData[partName]
        local partValue = partData and partData.information and tonumber(partData.information.value) or 700
        valueLost = valueLost + partValue * delta
      end
    end
  end
  local catalogValue = math.max(tonumber(job.vehicleValue) or 1000, 1)
  return math.min(valueLost / catalogValue, 0.5), valueLost
end

local function promoteKeptVehicle(job, finalConditions, callback)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    callback(nil)
    return
  end
  -- Teleports, resets, and other recovery tools may replenish fuel. Enforce
  -- the reward rule again at handoff so the awarded vehicle always has one
  -- litre, regardless of how it reached the yard.
  setOneLiter(job, vehicle, function()
    local temporaryId = job.inventoryId
    local noFreeSlot = not (career_modules_inventory.hasFreeSlot and career_modules_inventory.hasFreeSlot())
    local newInventoryId = career_modules_inventory.addVehicle(vehicle:getID(), nil, {
      owned = true,
      takesNoInventorySpace = noFreeSlot,
      skipPartConditionInit = true,
      finalPrice = 0
    })
    if not newInventoryId then
      callback(nil)
      return
    end
    local record = career_modules_inventory.getVehicles()[newInventoryId]
    if record then
      record.partConditions = deepcopy(finalConditions or {})
      local finalMileage = tonumber(job.mileage) or 0
      for _, condition in pairs(finalConditions or {}) do
        finalMileage = math.max(finalMileage, tonumber(condition.odometer) or 0)
      end
      record.year = job.year
      record.mileage = finalMileage
      record.purchasePrice = 0
      record.rewardSource = "Off-Road Recovery"
      record.offroadRecoveryContract = nil
      record.offroadRecoveryJobId = nil
      if record.config then record.config.isRecovery = nil end
      if noFreeSlot then record.takesNoInventorySpace = true end
    end
    if temporaryId and career_modules_inventory.getVehicles()[temporaryId] then
      career_modules_inventory.removeVehicle(temporaryId)
    end
    -- Must register explicitly as uninsured. Without this, a recycled numeric
    -- inventory id can inherit a previous vehicle's insurance.json entry.
    extensions.hook("onVehicleAddedToInventory", {
      inventoryId = newInventoryId,
      purchaseData = {insuranceId = -1},
    })
    runtimeByVehicleId[vehicle:getID()] = nil
    job.inventoryId = nil
    local pathName = damageFilePath(job.id)
    if pathName and FS:fileExists(pathName) then FS:removeFile(pathName) end
    callback(newInventoryId)
  end)
end

local function finishCompletion(job, finalConditions)
  local penalty, damageValue = damagePenalty(job, finalConditions)
  local multiplier = 1 - penalty
  local finalXp = math.max(0, math.floor((tonumber(job.baseSkillXp) or 0) * multiplier + 0.5))
  local finalCash = job.rewardType == "cash" and math.max(0, math.floor((tonumber(job.cashReward) or 0) * multiplier + 0.5)) or 0
  local rewardData = {[SKILL_ATTRIBUTE] = {amount = finalXp}}
  if finalCash > 0 then rewardData.money = {amount = finalCash} end
  if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
    career_modules_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  end
  finalXp = rewardData[SKILL_ATTRIBUTE] and rewardData[SKILL_ATTRIBUTE].amount or finalXp
  local function finalize(keptInventoryId)
    if job.rewardType == "vehicle" and not keptInventoryId then
      job.completing = nil
      job.status = "active"
      ui_message("The recovered vehicle could not be transferred to your inventory.", 10, "Recovery", "warning")
      return
    end
    career_modules_payment.reward(rewardData, {
      label = job.rewardType == "vehicle"
        and string.format("Recovered %s %s - vehicle awarded", job.brand, job.name)
        or string.format("Recovered %s %s - paid $%d", job.brand, job.name, finalCash),
      tags = {"gameplay", "reward", "offroadRecovery"}
    }, true)

    local function afterCleanup()
      removeJobFromState(job)
      refreshTrackedRoute()
      local breakdown = buildCompletionBreakdown(job, finalCash, finalXp, penalty)
      lastCompletion = {
        jobId = job.id,
        brand = job.brand,
        name = job.name,
        year = job.year,
        rewardType = job.rewardType,
        money = finalCash,
        xp = finalXp,
        penaltyPercent = math.floor(penalty * 100 + 0.5),
        damageValue = math.floor(damageValue + 0.5),
        keptInventoryId = keptInventoryId,
        breakdown = breakdown
      }
      showCompletionTasklist(breakdown, "Recovery Complete")
      openRecoveryApp()
      ui_message(
        string.format("%s %s recovered.\nDamage penalty: %d%%%s",
          job.brand, job.name, lastCompletion.penaltyPercent,
          job.rewardType == "vehicle" and "\nThe vehicle is now yours." or string.format("\nPaid $%d", finalCash)),
        12, "Recovery Complete", "info")
      saveState()
      if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
      M.requestState()
    end

    if job.rewardType == "cash" then
      cleanupTemporaryTarget(job, afterCleanup)
    else
      afterCleanup()
    end
  end
  if job.rewardType == "vehicle" then
    promoteKeptVehicle(job, finalConditions, finalize)
  else
    finalize(nil)
  end
end

local function completeJob(job)
  if not job or job.completing or job.status ~= "active" then return end
  job.completing = true
  career_modules_inventory.updatePartConditions(job.vehicleId, job.inventoryId, function()
    local record = career_modules_inventory.getVehicles()[job.inventoryId]
    local finalConditions = deepcopy(record and record.partConditions or {})
    finishCompletion(job, finalConditions)
  end)
end

local function objectivePosition(job)
  if not job then return nil end
  if job.phase == "delivery" then return arrayToVec3(job.deliveryPos) end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  return vehicle and vehicle:getPosition() or arrayToVec3(job.targetPos)
end

refreshTrackedRoute = function(force)
  local mapState = currentMap and getMapState(currentMap)
  local job = mapState and findJob(mapState.trackedJobId)
  if not job or job.mapId ~= currentMap or job.status == "missing" then
    if trackedRouteActive and core_groundMarkers then core_groundMarkers.setPath(nil) end
    trackedRouteKey = nil
    trackedRouteActive = false
    return
  end
  local routeKey = tostring(job.id) .. ":" .. tostring(job.phase)
  if not force and trackedRouteActive and trackedRouteKey == routeKey then return end
  local pos = objectivePosition(job)
  if pos and core_groundMarkers then
    core_groundMarkers.setPath(pos, {clearPathOnReachingTarget = false})
    trackedRouteKey = routeKey
    trackedRouteActive = true
  end
end

local function updateJob(job)
  if job.mapId ~= currentMap or job.status ~= "active" then return end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then
    runtimeByVehicleId[job.vehicleId] = nil
    job.vehicleId = nil
    job.status = "missing"
    job.completing = nil
    refreshTrackedRoute()
    return
  end
  local vehiclePos = vehicle:getPosition()
  -- Spawn settle on a slope can move a wreck more than 8 m in 3D and used
  -- to flip the job to delivery, which sent nav back to the yard.
  if job.phase ~= "delivery" and job.status == "active" then
    local playerPos = getPlayerPosition()
    local original = arrayToVec3(job.originalTargetPos or job.targetPos)
    local dx = vehiclePos.x - original.x
    local dy = vehiclePos.y - original.y
    local extracted = (dx * dx + dy * dy) >= (25 * 25)
    local playerNear = playerPos and playerPos:distance(vehiclePos) <= 20
    if playerNear or extracted then
      job.phase = "delivery"
      refreshTrackedRoute()
    end
  end
  if isInYardDropoff(job, vehiclePos) and vehicle:getVelocity():length() <= DELIVERY_MAX_SPEED then
    completeJob(job)
  end
end

local function expireOffers()
  for index = #availableOffers, 1, -1 do
    if simMinutes >= (availableOffers[index].expiresAt or 0) then removeOfferAt(index) end
  end
end

local function offersAvailableReason()
  if not currentMap then return false, "Enter a supported career map." end
  if getSkillLevel() < 5 then return false, "Reach Recovery level 5 to accept Off-Road Recovery contracts." end
  if economyMultiplier() <= 0 then return false, "Off-Road Recovery is disabled by the current economy settings." end
  local yards = getOwnedRecoveryYards()
  if #yards == 0 then return false, "Purchase or finance a Recovery Yard on this map to accept contracts.", yards end
  local data = loadRecoverySites()
  if not (data and data.parkingSpots and data.parkingSpots.objects and next(data.parkingSpots.objects)) then
    return false, "This map has no Off-Road Recovery locations.", yards
  end
  return true, nil, yards
end

local function initializeBoard()
  local eligible = offersAvailableReason()
  if eligible and not boardEligible then
    boardEligible = true
    availableOffers = {}
    pendingOfferId = nil
    generateOffer()
    nextOfferAt = simMinutes + OFFER_INTERVAL_MINUTES
  elseif not eligible and boardEligible then
    boardEligible = false
    availableOffers = {}
    pendingOfferId = nil
    nextOfferAt = nil
  end
end

local function offerUiData(offer, showCashReward)
  local playerPos = getPlayerPosition()
  return {
    id = offer.id,
    brand = offer.brand,
    name = offer.name,
    year = offer.year,
    tierLabel = offer.tierLabel,
    rewardType = offer.rewardType,
    cashReward = offer.rewardType == "cash" and showCashReward and offer.cashReward or nil,
    distance = playerPos and playerPos:distance(arrayToVec3(offer.targetPos)) or 0,
    expiresIn = math.max(0, math.ceil(((offer.expiresAt or simMinutes) - simMinutes) * 60))
  }
end

local function jobUiData(job)
  local objective = objectivePosition(job)
  local playerPos = getPlayerPosition()
  return {
    id = job.id,
    mapId = job.mapId,
    brand = job.brand,
    name = job.name,
    year = job.year,
    tierLabel = job.tierLabel,
    rewardType = job.rewardType,
    cashReward = job.rewardType == "cash" and job.cashReward or nil,
    yardName = job.yardName,
    status = job.status,
    phase = job.phase,
    tracked = job.mapId == currentMap and getMapState(currentMap).trackedJobId == job.id,
    distance = playerPos and objective and playerPos:distance(objective) or 0
  }
end

local function yardChoicesForPending()
  local offer = pendingOfferId and findOffer(pendingOfferId)
  if not offer then return {} end
  local choices = {}
  for _, yard in ipairs(getOwnedRecoveryYards()) do
    local cash, distance = fixedCashQuote(offer, yard)
    choices[#choices + 1] = {
      id = yard.id,
      name = yard.name,
      rewardType = offer.rewardType,
      cashReward = offer.rewardType == "cash" and cash or nil,
      distance = distance
    }
  end
  return choices
end

function M.getState()
  local eligible, reason, yards = offersAvailableReason()
  local mapState = currentMap and getMapState(currentMap)
  local offers, activeJobs, otherMapJobs = {}, {}, {}
  local showCashReward = yards and #yards == 1
  for _, offer in ipairs(availableOffers) do offers[#offers + 1] = offerUiData(offer, showCashReward) end
  table.sort(offers, function(a, b) return a.expiresIn < b.expiresIn end)
  for _, job in ipairs(mapState and mapState.jobs or {}) do activeJobs[#activeJobs + 1] = jobUiData(job) end
  for mapId, otherState in pairs(state.maps or {}) do
    if mapId ~= currentMap then
      for _, job in ipairs(otherState.jobs or {}) do otherMapJobs[#otherMapJobs + 1] = jobUiData(job) end
    end
  end
  return {
    mapId = currentMap,
    locked = not eligible,
    lockedReason = reason,
    skillLevel = getSkillLevel(),
    payoutBonusPercent = getPayoutBonus(getSkillLevel()),
    offers = offers,
    activeJobs = activeJobs,
    otherMapJobs = otherMapJobs,
    activeCount = #(mapState and mapState.jobs or {}),
    maxActive = MAX_ACTIVE_PER_MAP,
    pendingOfferId = pendingOfferId,
    yardChoices = yardChoicesForPending(),
    lastCompletion = lastCompletion
  }
end

function M.requestState()
  guihooks.trigger("updateOffroadRecoveryState", M.getState())
end

local function commitOffer(offer, yard)
  local cashReward, distance, payBreakdown = fixedCashQuote(offer, yard)
  local job = {
    id = nextContractId("job"),
    mapId = currentMap,
    spotName = offer.spotName,
    originalTargetPos = deepcopy(offer.targetPos),
    targetPos = deepcopy(offer.targetPos),
    targetRot = deepcopy(offer.targetRot),
    model = offer.model,
    configKey = offer.configKey,
    brand = offer.brand,
    name = offer.name,
    year = offer.year,
    mileage = offer.mileage,
    vehicleType = offer.vehicleType,
    recoveryTag = offer.recoveryTag,
    tierLabel = offer.tierLabel,
    payMultiplier = offer.payMultiplier,
    baseXp = offer.baseXp,
    vehicleValue = offer.vehicleValue,
    rewardType = offer.rewardType,
    cashReward = offer.rewardType == "cash" and cashReward or 0,
    payBreakdown = offer.rewardType == "cash" and payBreakdown or nil,
    routeDistance = distance,
    baseSkillXp = fixedSkillXp(offer, distance),
    condition = offer.condition,
    missingWheelCount = offer.missingWheelCount,
    wheelSeed = offer.wheelSeed,
    yardId = yard.id,
    yardName = yard.name,
    deliverySpotName = yard.spotName,
    deliveryPos = toVec3Array(yard.spot.pos),
    deliveryRot = toQuatArray(yard.spot.rot or quat(0, 0, 0, 1)),
    phase = "pickup",
    status = "spawning"
  }
  local mapState = getMapState(currentMap)
  mapState.jobs[#mapState.jobs + 1] = job
  mapState.trackedJobId = job.id
  local _, offerIndex = findOffer(offer.id)
  if offerIndex then removeOfferAt(offerIndex) end
  pendingOfferId = nil
  spawnJobTarget(job, false)
  refreshTrackedRoute()
  saveState()
  M.requestState()
  return true
end

function M.beginAcceptOffer(offerId)
  local offer = findOffer(offerId)
  if not offer or simMinutes >= (offer.expiresAt or 0) then
    M.requestState()
    return {accepted = false, reason = "Offer expired"}
  end
  if activeCount(currentMap) >= MAX_ACTIVE_PER_MAP then
    return {accepted = false, reason = "This map already has three active recoveries"}
  end
  local eligible, reason = offersAvailableReason()
  if not eligible then return {accepted = false, reason = reason} end
  local yards = getOwnedRecoveryYards()
  if #yards == 1 then
    commitOffer(offer, yards[1])
    return {accepted = true}
  end
  pendingOfferId = offerId
  M.requestState()
  return {accepted = false, needsYard = true}
end

function M.selectRecoveryYard(yardId)
  local offer = pendingOfferId and findOffer(pendingOfferId)
  if not offer then return {accepted = false, reason = "Offer is no longer available"} end
  for _, yard in ipairs(getOwnedRecoveryYards()) do
    if yard.id == yardId then
      commitOffer(offer, yard)
      return {accepted = true}
    end
  end
  return {accepted = false, reason = "Recovery Yard is no longer owned"}
end

function M.cancelYardSelection()
  pendingOfferId = nil
  M.requestState()
end

function M.previewOffer(offerId)
  local offer = findOffer(offerId)
  if not offer then return false end
  local poiId = "offroadRecoveryOffer-" .. offer.id
  if freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap then
    returnToOfferBoardAfterMap = true
    if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
    freeroam_bigMapMode.enterBigMap({
      instant = true,
      autoSelectPoiId = poiId
    })
    return true
  end
  return false
end

local function onDeactivateBigMapCallback()
  if not returnToOfferBoardAfterMap then return end
  returnToOfferBoardAfterMap = false
  if extensions and extensions.ui_router then
    extensions.ui_router.navigate("phone-offroad-recovery")
  end
end

function M.trackJob(jobId)
  local job = findJob(jobId)
  if not job or job.mapId ~= currentMap then return false end
  getMapState(currentMap).trackedJobId = job.id
  refreshTrackedRoute(true)
  saveState()
  M.requestState()
  return true
end

function M.abandonJob(jobId)
  local job = findJob(jobId)
  if not job then return false end
  -- Drop the contract from state immediately; soft-delete the world object async
  -- so hauler coupler locks can settle without blocking abandon.
  removeJobFromState(job)
  local function afterCleanup()
    saveState()
    refreshTrackedRoute()
    M.requestState()
  end
  local cleanupOk, cleanupError = pcall(cleanupTemporaryTarget, job, afterCleanup)
  if not cleanupOk then
    -- A removed or broken vehicle mod must never prevent the contract itself
    -- from being abandoned and removed from the career save.
    log("W", LOG_TAG, "Recovery target cleanup failed during abandon: " .. tostring(cleanupError))
    afterCleanup()
  end
  return true
end

function M.clearCompletion()
  lastCompletion = nil
  clearTasklistTimer = nil
  guihooks.trigger("ClearTasklist")
  M.requestState()
end

function M.isContractTarget(vehicleId)
  return runtimeByVehicleId[tonumber(vehicleId)] ~= nil
end

function M.isContractInventoryId(inventoryId)
  if not inventoryId or not career_modules_inventory then return false end
  local record = career_modules_inventory.getVehicles()[inventoryId]
  return record and record.offroadRecoveryContract == true
end

function M.blocksJobShifts(vehicleId)
  if M.isContractTarget(vehicleId) then return true end
  if not vehicleId or not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
    return false
  end
  return M.isContractInventoryId(career_modules_inventory.getInventoryIdFromVehicleId(vehicleId))
end

local blockedPermissionTags = {
  interactRefuel = true,
  vehicleRepair = true,
  vehicleModification = true,
  partBuying = true,
  partSwapping = true,
  painting = true,
  tuning = true,
  vehicleStoring = true,
  vehicleSelling = true,
  vehicleLicensePlate = true,
  vehicleFavorite = true,
  returnLoanedVehicle = true,
  recoveryTowToGarage = true,
  recoveryTowToRoad = true
}

function M.onCheckPermission(tags, permissions, additionalData)
  if not additionalData or not M.isContractInventoryId(additionalData.inventoryId) then return end
  for _, tag in ipairs(tags or {}) do
    if blockedPermissionTags[tag] then
      table.insert(permissions, {permission = "forbidden", label = "Contract targets must be recovered manually."})
      return
    end
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if levelIdentifier ~= currentMap then return end
  for _, offer in ipairs(availableOffers) do
    table.insert(elements, {
      id = "offroadRecoveryOffer-" .. offer.id,
      data = {type = "events", offroadRecoveryType = "offer", id = offer.id},
      markerInfo = {bigmapMarker = {
        pos = arrayToVec3(offer.targetPos),
        icon = "tow",
        name = "Off-Road Recovery Offer",
        description = string.format("%s %s - %.1f km away", offer.brand, offer.name,
          (getPlayerPosition() and getPlayerPosition():distance(arrayToVec3(offer.targetPos)) or 0) / 1000),
        cluster = false
      }}
    })
  end
  for _, job in ipairs(getMapState(currentMap).jobs or {}) do
    local pos = objectivePosition(job)
    if pos then
      table.insert(elements, {
        id = "offroadRecoveryJob-" .. job.id,
        data = {type = "events", offroadRecoveryType = "job", id = job.id},
        markerInfo = {bigmapMarker = {
          pos = pos,
          icon = "tow",
          name = string.format("Recovery: %s %s", job.brand, job.name),
          description = job.phase == "delivery" and ("Return to " .. job.yardName) or "Recover the stranded target",
          cluster = false
        }}
      })
    end
  end
end

local function restoreCurrentMapJobs()
  local mapState = currentMap and getMapState(currentMap)
  runtimeByVehicleId = {}
  for _, job in ipairs(mapState and mapState.jobs or {}) do
    job.mapId = currentMap
    job.spawnPending = nil
    job.completing = nil
    local existingVehicleId = job.inventoryId and career_modules_inventory
      and career_modules_inventory.getVehicleIdFromInventoryId(job.inventoryId)
    if existingVehicleId and getObjectByID(existingVehicleId) then
      job.vehicleId = existingVehicleId
      runtimeByVehicleId[existingVehicleId] = job.id
      job.status = "active"
      updateJobSnapshotFromInventory(job)
    else
      job.vehicleId = nil
    end
    if job.status ~= "missing" and not job.vehicleId then
      job.status = "paused"
      spawnJobTarget(job, job.vehicleSnapshot ~= nil)
    end
  end
  refreshTrackedRoute(true)
end

local function worldReady()
  local newMap = getCurrentLevelIdentifier()
  if not newMap then return end
  if currentMap and currentMap ~= newMap then
    availableOffers = {}
    pendingOfferId = nil
  end
  currentMap = newMap
  sitesCache, sitesCacheMap = nil, nil
  dropoffZonesByYardId = {}
  vehiclePoolCache, vehiclePoolSkillLevel = nil, nil
  availableOffers = {}
  pendingOfferId = nil
  boardEligible = false
  nextOfferAt = nil
  -- Let the first update seed the board. Building the vehicle pool can be
  -- expensive, and doing it here stalls career/module activation.
  restoreCurrentMapJobs()
  M.requestState()
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and career_career and career_career.isActive() then worldReady() end
end

local function onExtensionLoaded()
  math.randomseed(os.time())
  loadFilters()
  if career_career and career_career.isActive() then
    loadState()
    currentMap = getCurrentLevelIdentifier()
    if currentMap then worldReady() end
  end
  initialized = true
end

local function onCareerModulesActivated()
  loadState()
  currentMap = getCurrentLevelIdentifier()
  if currentMap then worldReady() end
  initialized = true
end

local function onClientEndMission()
  local savePath = currentSavePath()
  if currentMap then
    for _, job in ipairs(getMapState(currentMap).jobs or {}) do
      if job.status ~= "missing" then
        captureExitState(job, savePath)
        job.status = "paused"
      end
      job.vehicleId = nil
      job.spawnPending = nil
      job.completing = nil
    end
  end
  runtimeByVehicleId = {}
  availableOffers = {}
  pendingOfferId = nil
  boardEligible = false
  if trackedRouteActive and core_groundMarkers then core_groundMarkers.setPath(nil) end
  trackedRouteKey = nil
  trackedRouteActive = false
  saveStateToPath(savePath)
end

local function onSaveCurrentProfileAsyncStart()
  saveRegistered = false
  saveGenerationToken = nil
  if hasSpawnedCurrentMapJob() and career_saveSystem and career_saveSystem.registerAsyncSaveExtension then
    saveGenerationToken = career_saveSystem.registerAsyncSaveExtension(ASYNC_SAVE_EXTENSION)
    saveRegistered = true
  end
end

local function onSaveCurrentProfile(savePath)
  if saveRegistered then
    beginCareerSave(savePath)
  else
    stageDamageSnapshots(currentSavePath(), savePath)
    saveStateToPath(savePath)
  end
end

local function onVehicleSaveFinished(savePath)
  local pending = pendingCareerSave
  if not pending or pending.savePath ~= savePath then return end
  for _, entry in pairs(pending.jobs) do updateJobSnapshotFromInventory(entry.job) end
  pending.inventoryReady = true
  finishCareerSave(false)
end

local function onExtensionUnloaded()
  if pendingCareerSave then finishCareerSave(true) end
  if currentMap then
    for _, job in ipairs(getMapState(currentMap).jobs or {}) do capturePose(job) end
  end
  saveState()
  if trackedRouteActive and core_groundMarkers then core_groundMarkers.setPath(nil) end
  trackedRouteKey = nil
  trackedRouteActive = false
end

local function onVehicleDestroyed(vehicleId)
  local jobId = runtimeByVehicleId[vehicleId]
  if not jobId then return end
  local job = findJob(jobId)
  runtimeByVehicleId[vehicleId] = nil
  if job and not job.completing then
    job.vehicleId = nil
    job.status = "missing"
    saveState()
    refreshTrackedRoute()
    M.requestState()
  end
end

local function onUpdate(dtReal, dtSim)
  if not initialized or not career_career or not career_career.isActive() then return end
  simMinutes = simMinutes + math.max(tonumber(dtSim) or 0, 0) / 60
  updateTimer = updateTimer + (tonumber(dtSim) or 0)
  uiTimer = uiTimer + (tonumber(dtReal) or 0)
  if clearTasklistTimer then
    clearTasklistTimer = clearTasklistTimer - math.max(tonumber(dtReal) or 0, 0)
    if clearTasklistTimer <= 0 then
      clearTasklistTimer = nil
      guihooks.trigger("ClearTasklist")
    end
  end
  if pendingCareerSave then
    pendingCareerSave.elapsed = pendingCareerSave.elapsed + math.max(tonumber(dtReal) or 0, 0)
    if pendingCareerSave.elapsed >= SAVE_TIMEOUT_SECONDS then finishCareerSave(true) end
  end
  initializeBoard()
  expireOffers()
  if boardEligible and offerCount() < MAX_OFFERS and nextOfferAt and simMinutes >= nextOfferAt then
    generateOffer()
    nextOfferAt = simMinutes + OFFER_INTERVAL_MINUTES
  end
  if updateTimer >= 0.5 then
    updateTimer = 0
    for _, job in ipairs(currentMap and getMapState(currentMap).jobs or {}) do updateJob(job) end
  end
  if uiTimer >= 1 then
    uiTimer = 0
    M.requestState()
  end
end

M.onWorldReadyState = onWorldReadyState
M.onExtensionLoaded = onExtensionLoaded
M.onCareerModulesActivated = onCareerModulesActivated
M.onClientEndMission = onClientEndMission
M.onSaveCurrentProfileAsyncStart = onSaveCurrentProfileAsyncStart
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onVehicleSaveFinished = onVehicleSaveFinished
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleDestroyed = onVehicleDestroyed
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback
M.onUpdate = onUpdate

return M
