local M = {}

M.dependencies = {"career_career", "career_saveSystem"}

local logTag = "rlsDynamicWeather"
local saveRelativePath = "/career/rls_career/weather.json"
local legacyTimeRelativePath = "/career/rls_career/time.json"
local globalSettingsPath = "settings/RLS/weather.json"
local schemaVersion = 1
-- Bumped when forecast generation rules change so retained horizon days rebuild.
local generatorVersion = 2
local travelMinutes = 8 * 60
local stateTickSeconds = 1
local visualTickSeconds = 0.2
local wetMaterialTickSeconds = 0.1

local CONDITION_ORDER = {"clear", "partlyCloudy", "overcast", "drizzle", "rain", "storm"}
local CONDITION_INDEX = {}
for i, name in ipairs(CONDITION_ORDER) do CONDITION_INDEX[name] = i end

local EFFECTS = {
  clear        = {fogAdd = 0,      sky = 1.00, sun = 1.00, ambient = 1.00, brightness = 1.00, rain = 0,    wetRough = 0,    wind = 0.04, tint = {1.00, 1.00, 1.00}},
  partlyCloudy = {fogAdd = 0.0004, sky = 0.86, sun = 0.76, ambient = 0.92, brightness = 0.84, rain = 0,    wetRough = 0,    wind = 0.16, tint = {0.91, 0.93, 0.97}},
  overcast     = {fogAdd = 0.0015, sky = 0.64, sun = 0.18, ambient = 0.79, brightness = 0.58, rain = 0,    wetRough = 0,    wind = 0.24, tint = {0.72, 0.75, 0.80}},
  drizzle      = {fogAdd = 0.0030, sky = 0.53, sun = 0.08, ambient = 0.69, brightness = 0.44, rain = 1200, wetRough = 0.28, wind = 0.32, tint = {0.63, 0.67, 0.73}},
  rain         = {fogAdd = 0.0045, sky = 0.43, sun = 0.03, ambient = 0.61, brightness = 0.32, rain = 2200, wetRough = 0.18, wind = 0.45, tint = {0.55, 0.59, 0.66}},
  storm        = {fogAdd = 0.0070, sky = 0.28, sun = 0.01, ambient = 0.49, brightness = 0.19, rain = 3400, wetRough = 0.10, wind = 0.70, tint = {0.41, 0.46, 0.56}},
}

local CONDITION_META = {
  clear        = {humidity = 36, precipitation = 5,  windMph = 3,  tempOffsetC = 1.5},
  partlyCloudy = {humidity = 48, precipitation = 16, windMph = 7,  tempOffsetC = 0.5},
  overcast     = {humidity = 64, precipitation = 32, windMph = 10, tempOffsetC = -1.0},
  drizzle      = {humidity = 80, precipitation = 65, windMph = 12, tempOffsetC = -1.8},
  rain         = {humidity = 89, precipitation = 88, windMph = 16, tempOffsetC = -2.8},
  storm        = {humidity = 94, precipitation = 98, windMph = 24, tempOffsetC = -3.5},
}

local state
local profile
local globalSettings = {temperatureUnit = "F", vulkanSafeMode = false, visualWindScale = 1}
local careerActive = false
local worldReady = false
local loaded = false
local initializedMapId = nil
local missionFrozen = false
local travelJournalOverrideActive = false
local externalOverride = false
local externalWarningShown = false
local stateTick = 0
local visualTick = 0
local wetMaterialTick = 0
local lastUiSignature = nil
local lastConditionKey = nil
local lastGripBucket = nil
local currentConditionName = "clear"
local lastAppliedTimeOfDay = nil
local notificationHistory = {}

local baseline
local currentEffect = {}
local effectFrom = {}
local effectTarget = {}
local transitionElapsed = 0
local transitionDuration = 0
local transitioning = false
local rainShown = 0
local audioRainTimer = 0
local thunderTimer = -1
local thunderCooldown = 0
local environmentApplied = false
local lastExternalMinute

local ROAD_WORDS = {"road", "asphalt", "concrete", "pavement", "tarmac", "sidewalk", "curb", "kerb", "track", "blacktop", "macadam", "raceway", "speedway", "circuit", "racetrack", "cobble"}
local ROAD_EXCLUDE_WORDS = {"sky", "cloud", "glass", "window", "water", "tree", "foliage", "grass", "plant", "leaf", "wheel", "tire", "glow", "decal", "sign", "smoke", "fire", "emissive", "grid", "border", "crack", "crossing", "skidmark", "marking", "arrow", "paint"}
local savedRoughness = {}
local savedDiffuse = {}
local wetMaterialQueue = {}
local wetTargetRoughness = 0
local wetAppliedRoughness = 0
local soundBase

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function copyTable(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copyTable(v) end
  return out
end

local function deepMerge(base, override)
  local out = copyTable(base or {})
  if type(override) ~= "table" then return out end
  if #override > 0 then return copyTable(override) end
  for k, v in pairs(override) do
    if type(v) == "table" and type(out[k]) == "table" and #v == 0 then
      out[k] = deepMerge(out[k], v)
    else
      out[k] = copyTable(v)
    end
  end
  return out
end

local function ensureDirectory(path)
  if not FS:directoryExists(path) then FS:directoryCreate(path, true) end
end

local function writeJson(path, data)
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    return career_saveSystem.jsonWriteFileSafe(path, data, true)
  end
  if jsonWriteFileSafe then return jsonWriteFileSafe(path, data, true) end
  return jsonWriteFile(path, data, true)
end

local function getSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentProfile then return nil end
  local _, path = career_saveSystem.getCurrentProfile()
  return path
end

local function getMapId()
  return (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or "unknown"
end

local function engineTimeToMinute(t)
  return math.floor((((tonumber(t) or 0) + 0.5) % 1) * 1440 + 0.5) % 1440
end

local function minuteToEngineTime(minute)
  return (((tonumber(minute) or 0) / 1440) + 0.5) % 1
end

local function hashString(value)
  local h = 2166136261
  value = tostring(value or "")
  for i = 1, #value do
    h = (h * 16777619 + value:byte(i)) % 4294967296
  end
  return h
end

local function makeRng(seed)
  local n = math.floor(tonumber(seed) or 1) % 4294967296
  if n == 0 then n = 1 end
  return function()
    n = (1664525 * n + 1013904223) % 4294967296
    return n / 4294967296
  end
end

local function seededFor(dayIndex, epoch, mapId)
  return (state.seed + hashString(mapId) + (dayIndex or 0) * 2654435761 + (epoch or 0) * 2246822519 + generatorVersion * 3266489917) % 4294967296
end

local function loadProfile()
  local defaultProfile = jsonReadFile("/gameplay/rls_weather/default.json") or {}
  local mapId = getMapId()
  local mapProfile = jsonReadFile("/levels/" .. mapId .. "/rls_weather.json")
  profile = deepMerge(defaultProfile, mapProfile or {})
  profile.displayName = profile.displayName or mapId
  profile.conditionWeights = profile.conditionWeights or {}
  profile.conditionDurationsMinutes = profile.conditionDurationsMinutes or {}
  profile.morningFog = profile.morningFog or {}
  profile.temperatureCurveC = profile.temperatureCurveC or {{0, 13}, {720, 23}, {1440, 13}}
  profile.dailyTemperatureVarianceC = tonumber(profile.dailyTemperatureVarianceC) or 2.5
  profile.transitionMinutes = tonumber(profile.transitionMinutes) or 20
  profile.wetness = profile.wetness or {}
  return profile
end

local function loadGlobalSettings()
  local raw = jsonReadFile(globalSettingsPath)
  if type(raw) == "table" then
    globalSettings.temperatureUnit = raw.temperatureUnit == "C" and "C" or "F"
    -- Rain particles and the wet-road pass are now always enabled. Ignore the
    -- retired safe-mode value so older settings cannot silently disable them.
    globalSettings.vulkanSafeMode = false
    globalSettings.visualWindScale = clamp(tonumber(raw.visualWindScale) or 1, 0, 2)
  end
end

local function saveGlobalSettings()
  ensureDirectory("settings/RLS/")
  writeJson(globalSettingsPath, globalSettings)
end

local function defaultState()
  local currentEngineTime = scenetree and scenetree.tod and scenetree.tod.time or 0
  local profileName = "career"
  if career_saveSystem and career_saveSystem.getCurrentProfile then
    profileName = select(1, career_saveSystem.getCurrentProfile()) or profileName
  end
  return {
    version = schemaVersion,
    generatorVersion = generatorVersion,
    seed = (hashString(profileName) + (os.time and os.time() or 1)) % 4294967296,
    dayIndex = 0,
    minuteOfDay = engineTimeToMinute(currentEngineTime),
    forecastEpoch = 0,
    activeMap = getMapId(),
    horizon = {},
    wetness = 0,
    playCycle = true,
    settings = {
      dynamicWeather = true,
      allowRainyDays = true,
      dayLengthMinutes = 60,
      forecastNotifications = true,
    },
  }
end

local function normalizeState(raw)
  local out = type(raw) == "table" and raw or defaultState()
  out.version = schemaVersion
  out.generatorVersion = tonumber(out.generatorVersion) or generatorVersion
  out.seed = tonumber(out.seed) or defaultState().seed
  out.dayIndex = math.max(0, math.floor(tonumber(out.dayIndex) or 0))
  out.minuteOfDay = (tonumber(out.minuteOfDay) or 720) % 1440
  out.forecastEpoch = math.max(0, math.floor(tonumber(out.forecastEpoch) or 0))
  out.activeMap = type(out.activeMap) == "string" and out.activeMap or getMapId()
  out.horizon = type(out.horizon) == "table" and out.horizon or {}
  out.wetness = clamp(tonumber(out.wetness) or 0, 0, 1)
  out.playCycle = out.playCycle ~= false
  out.settings = type(out.settings) == "table" and out.settings or {}
  if out.settings.dynamicWeather == nil then out.settings.dynamicWeather = true end
  if out.settings.allowRainyDays == nil then out.settings.allowRainyDays = true end
  out.settings.dayLengthMinutes = tonumber(out.settings.dayLengthMinutes) or 60
  if not ({[30]=true,[45]=true,[60]=true,[90]=true,[120]=true})[out.settings.dayLengthMinutes] then out.settings.dayLengthMinutes = 60 end
  if out.settings.forecastNotifications == nil then out.settings.forecastNotifications = true end
  return out
end

local function pickWeighted(rng, previous)
  local previousIndex = CONDITION_INDEX[previous]
  local candidates = {}
  local total = 0
  for i, name in ipairs(CONDITION_ORDER) do
    local eligible = not previousIndex or math.abs(i - previousIndex) <= 1
    if name == "storm" and previous ~= "rain" and previous ~= "storm" then eligible = false end
    local weight = eligible and math.max(0, tonumber(profile.conditionWeights[name]) or 0) or 0
    if weight > 0 then
      total = total + weight
      candidates[#candidates + 1] = {name = name, cumulative = total}
    end
  end
  if total <= 0 then return previous or "clear" end
  local value = rng() * total
  for _, candidate in ipairs(candidates) do
    if value <= candidate.cumulative then return candidate.name end
  end
  return candidates[#candidates].name
end

local function durationFor(rng, condition)
  local range = profile.conditionDurationsMinutes[condition] or {120, 240}
  local lo = math.max(15, tonumber(range[1]) or 120)
  local hi = math.max(lo, tonumber(range[2]) or lo)
  return math.floor((lo + (hi - lo) * rng()) / 15 + 0.5) * 15
end

local DEFAULT_MOISTURE_CONDITIONS = {overcast = true, drizzle = true, rain = true, storm = true}
local DEFAULT_CLEARING_MORNING = {clear = true, partlyCloudy = true, overcast = true, drizzle = true}

local function moistureConditionSet(fogCfg)
  local set = {}
  local list = fogCfg and fogCfg.moistureConditions
  if type(list) == "table" and #list > 0 then
    for _, name in ipairs(list) do set[name] = true end
    return set
  end
  return DEFAULT_MOISTURE_CONDITIONS
end

local function segmentConditionAt(segments, minute)
  for _, segment in ipairs(segments or {}) do
    if minute >= segment.startMinute and minute < segment.endMinute then
      return segment.condition
    end
  end
  local last = segments and segments[#segments]
  return last and last.condition or nil
end

-- Minutes of moist sky covering [0, windowEnd) on this day.
local function overnightMoistureMinutes(segments, windowEnd, moistureSet)
  local total = 0
  windowEnd = math.max(0, tonumber(windowEnd) or 360)
  for _, segment in ipairs(segments or {}) do
    if segment.startMinute < windowEnd and moistureSet[segment.condition] then
      local lo = math.max(segment.startMinute, 0)
      local hi = math.min(segment.endMinute, windowEnd)
      if hi > lo then total = total + (hi - lo) end
    end
  end
  return total
end

-- Overnight / pre-dawn fog after moist air. Clearing-morning bias is opt-in only;
-- building out of darkness under overcast is normal and allowed by default.
local function morningFogEligible(segments, previousCondition, fogCfg)
  if fogCfg.requireOvernightMoisture == false then return true end

  local moistureSet = moistureConditionSet(fogCfg)
  local windowEnd = tonumber(fogCfg.overnightWindowEndMinute) or 360
  local minMoisture = math.max(0, tonumber(fogCfg.minMoistureMinutes) or 90)
  local moistMinutes = overnightMoistureMinutes(segments, windowEnd, moistureSet)
  -- Previous day's last segment covers evening moisture that crossed midnight.
  if previousCondition and moistureSet[previousCondition] then
    moistMinutes = moistMinutes + math.min(120, minMoisture)
  end
  if moistMinutes < minMoisture then return false end

  if fogCfg.preferClearingMorning ~= true then return true end
  local startMinute = tonumber(fogCfg.startMinute) or 210
  local morning = segmentConditionAt(segments, startMinute)
  local clearing = fogCfg.clearingMorningConditions
  local clearingSet = DEFAULT_CLEARING_MORNING
  if type(clearing) == "table" and #clearing > 0 then
    clearingSet = {}
    for _, name in ipairs(clearing) do clearingSet[name] = true end
  end
  return morning ~= nil and clearingSet[morning] == true
end

local function buildForecastDay(dayIndex, previousCondition)
  local rng = makeRng(seededFor(dayIndex, state.forecastEpoch, state.activeMap))
  local segments = {}
  local minute = 0
  local condition = previousCondition
  while minute < 1440 do
    condition = pickWeighted(rng, condition)
    local duration = math.min(durationFor(rng, condition), 1440 - minute)
    segments[#segments + 1] = {startMinute = minute, endMinute = minute + duration, condition = condition}
    minute = minute + duration
  end
  local fog
  local fogCfg = profile.morningFog or {}
  if morningFogEligible(segments, previousCondition, fogCfg)
      and rng() < clamp(tonumber(fogCfg.chance) or 0, 0, 1) then
    local endMin = math.floor(lerp(tonumber(fogCfg.endMinuteMin) or 510, tonumber(fogCfg.endMinuteMax) or 540, rng()) + 0.5)
    fog = {
      startMinute = tonumber(fogCfg.startMinute) or 180,
      peakMinute = tonumber(fogCfg.peakMinute) or 390,
      clearMinute = tonumber(fogCfg.clearMinute) or 480,
      endMinute = endMin,
      maxDensity = tonumber(fogCfg.maxDensity) or 0.01,
      atmosphereHeight = tonumber(fogCfg.atmosphereHeight) or 190,
      fadeInPower = tonumber(fogCfg.fadeInPower) or 2,
    }
  end
  local variance = profile.dailyTemperatureVarianceC
  return {
    dayIndex = dayIndex,
    segments = segments,
    fog = fog,
    temperatureOffsetC = (rng() * 2 - 1) * variance,
    profileVersion = tonumber(profile.version) or 1,
    generatorVersion = generatorVersion,
  }
end

local function findDay(dayIndex)
  for _, day in ipairs(state.horizon or {}) do
    if day.dayIndex == dayIndex then return day end
  end
end

local function ensureHorizon()
  local retained = {}
  for _, day in ipairs(state.horizon or {}) do
    local sameGen = (tonumber(day.generatorVersion) or 0) == generatorVersion
    if sameGen and day.dayIndex >= state.dayIndex and day.dayIndex <= state.dayIndex + 6 then
      retained[#retained + 1] = day
    end
  end
  table.sort(retained, function(a, b) return a.dayIndex < b.dayIndex end)
  state.horizon = retained
  local previous
  if #retained > 0 and retained[#retained].segments and #retained[#retained].segments > 0 then
    previous = retained[#retained].segments[#retained[#retained].segments].condition
  end
  for dayIndex = state.dayIndex, state.dayIndex + 6 do
    local existing = findDay(dayIndex)
    if not existing then
      existing = buildForecastDay(dayIndex, previous)
      state.horizon[#state.horizon + 1] = existing
    end
    if existing.segments and #existing.segments > 0 then previous = existing.segments[#existing.segments].condition end
  end
  table.sort(state.horizon, function(a, b) return a.dayIndex < b.dayIndex end)
end

local function conditionAt(dayIndex, minute)
  local day = findDay(dayIndex)
  if not day then ensureHorizon(); day = findDay(dayIndex) end
  if not day then return "clear", nil, nil end
  for index, segment in ipairs(day.segments or {}) do
    if minute >= segment.startMinute and minute < segment.endMinute then return segment.condition, segment, day, index end
  end
  local segment = day.segments and day.segments[#day.segments]
  return segment and segment.condition or "clear", segment, day, day.segments and #day.segments or 0
end

local function effectiveCondition(condition)
  if not state.settings.dynamicWeather then return "clear" end
  if not state.settings.allowRainyDays and (condition == "drizzle" or condition == "rain" or condition == "storm") then return "overcast" end
  return condition
end

local function fogFactorAt(day, minute)
  local fog = day and day.fog
  if not fog or minute < fog.startMinute or minute >= fog.endMinute then return 0, nil end
  if minute <= fog.peakMinute then
    local t = clamp((minute - fog.startMinute) / math.max(1, fog.peakMinute - fog.startMinute), 0, 1)
    local power = tonumber(fog.fadeInPower) or 2
    return t ^ power, fog
  end
  if minute <= fog.clearMinute then return 1, fog end
  return clamp(1 - (minute - fog.clearMinute) / math.max(1, fog.endMinute - fog.clearMinute), 0, 1), fog
end

local function temperatureAt(dayIndex, minute)
  local day = findDay(dayIndex)
  local curve = profile.temperatureCurveC
  local value = tonumber(curve[1] and curve[1][2]) or 15
  for i = 1, #curve - 1 do
    local a, b = curve[i], curve[i + 1]
    if minute >= a[1] and minute <= b[1] then
      local p = (minute - a[1]) / math.max(1, b[1] - a[1])
      value = lerp(a[2], b[2], p)
      break
    end
  end
  local condition = conditionAt(dayIndex, minute)
  local meta = CONDITION_META[effectiveCondition(condition)] or CONDITION_META.clear
  return value + (day and day.temperatureOffsetC or 0) + (meta.tempOffsetC or 0)
end

local function daylightFactor(minute)
  if minute < 360 or minute > 1200 then return 0 end
  return math.sin(math.pi * (minute - 360) / 840)
end

local function surfaceTemperatureAt(dayIndex, minute, condition)
  local ambient = temperatureAt(dayIndex, minute)
  local effect = EFFECTS[effectiveCondition(condition)] or EFFECTS.clear
  local cloud = clamp(1 - effect.sky, 0, 1)
  local rain = effect.rain > 0 and clamp(effect.rain / 3400, 0, 1) or 0
  local calculated = ambient + 12 * daylightFactor(minute) * (1 - 0.8 * cloud) - 4 * rain
  return clamp(calculated, ambient - 4, ambient + 15), ambient
end

local function p4(value)
  if not value then return nil end
  local x = value.x or value.r
  local y = value.y or value.g
  local z = value.z or value.b
  local w = value.w or value.a or 1
  if x == nil then return nil end
  return {x, y, z, w}
end

local function scatterSky()
  if not (scenetree and scenetree.findObject) then return nil end
  local sky = scenetree.findObject("ScatterSky") or scenetree.findObject("sunsky") or scenetree.findObject("scattersky")
  if sky then return sky end
  for _, name in ipairs(scenetree.findClassObjects("ScatterSky") or {}) do
    sky = scenetree.findObject(name)
    if sky then return sky end
  end
end

local function levelInfo()
  if not (scenetree and scenetree.findObject) then return nil end
  local info = scenetree.findObject("theLevelInfo")
  if info then return info end
  for _, name in ipairs(scenetree.findClassObjects("LevelInfo") or {}) do
    info = scenetree.findObject(name)
    if info then return info end
  end
end

local function isPavedGroundModel(name, gm)
  local upper = string.upper(tostring(name or ""))
  for _, token in ipairs(profile.pavedCollisionTypes or {}) do
    if string.find(upper, string.upper(tostring(token)), 1, true) then return true end
  end
  local collision = gm and gm.cdata and tostring(gm.cdata.collisiontype or gm.cdata.collisionType or "") or ""
  collision = string.upper(collision)
  for _, token in ipairs(profile.pavedCollisionTypes or {}) do
    if collision == string.upper(tostring(token)) then return true end
  end
  return false
end

local function captureBaseline()
  if baseline then return end
  baseline = {groundModels = {}}
  baseline.fogDensity = core_environment and core_environment.getFogDensity and core_environment.getFogDensity() or 0.001
  baseline.timeOfDayPlay = scenetree and scenetree.tod and scenetree.tod.play
  local info = levelInfo()
  if info then
    baseline.fogAtmosphereHeight = tonumber(info.fogAtmosphereHeight)
    baseline.temperatureCurveC = info:getField("temperatureCurveC", 0)
  end
  local sky = scatterSky()
  if sky then
    baseline.skyBrightness = tonumber(sky.skyBrightness) or 1
    baseline.sunScale = p4(sky.sunScale)
    baseline.ambientScale = p4(sky.ambientScale)
    baseline.colorize = p4(sky.colorize)
    baseline.sunSize = tonumber(sky.sunSize)
    baseline.flareScale = tonumber(sky.flareScale)
    baseline.brightness = tonumber(sky.brightness)
  end
  if core_environment and core_environment.groundModels then
    for name, gm in pairs(core_environment.groundModels) do
      if gm and gm.cdata and isPavedGroundModel(name, gm) then
        baseline.groundModels[name] = {
          staticFrictionCoefficient = tonumber(gm.cdata.staticFrictionCoefficient),
          slidingFrictionCoefficient = tonumber(gm.cdata.slidingFrictionCoefficient),
          strength = tonumber(gm.cdata.strength),
        }
      end
    end
  end
end

local function clearRainObject(objectName)
  local object = scenetree and scenetree.findObject and scenetree.findObject(objectName)
  if object then object:delete() end
end

local function setRain(count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if globalSettings.vulkanSafeMode then count = 0 end
  if count == rainShown and (count == 0 or (scenetree and scenetree.findObject and scenetree.findObject("rlsDynamicWeatherRain"))) then return end
  clearRainObject("rlsDynamicWeatherRain")
  rainShown = count
  if count <= 0 or not (createObject and scenetree and scenetree.MissionGroup) then return end
  local object = createObject("Precipitation")
  if not object then return end
  object:setField("dataBlock", 0, "rain_drop")
  -- EFFECTS already stores the desired drop budget. Multiplying it here made
  -- storms render 10,200 alpha-blended particles, which is disproportionately
  -- expensive on the GPU.
  object:setField("numDrops", 0, tostring(count))
  object:setField("doCollision", 0, "false")
  object:setField("reflect", 0, "false")
  object:setField("useLighting", 0, "false")
  object:registerObject("rlsDynamicWeatherRain")
  scenetree.MissionGroup:addObject(object)
end

local function matchesAny(text, words)
  for _, word in ipairs(words) do
    if string.find(text, word, 1, true) then return true end
  end
  return false
end

local function collectRoadMaterials()
  local targets = {}
  local count = 0
  local cap = math.max(1, math.floor(tonumber(profile and profile.visualWetMaterialCap) or 24))
  local function add(materialName)
    if not materialName or materialName == "" or targets[materialName] or count >= cap then return end
    if matchesAny(string.lower(materialName), ROAD_EXCLUDE_WORDS) then return end
    targets[materialName] = true
    count = count + 1
  end
  local function addFromRoadObjects(className, fieldName)
    if not scenetree or not scenetree.findClassObjects then return end
    for _, objectName in ipairs(scenetree.findClassObjects(className) or {}) do
      if count >= cap then return end
      local object = scenetree.findObject(objectName)
      if object then
        local materialName = object:getField(fieldName, 0)
        if not materialName or materialName == "" then materialName = object:getField(fieldName, "") end
        add(materialName)
      end
    end
  end
  addFromRoadObjects("DecalRoad", "Material")
  addFromRoadObjects("MeshRoad", "topMaterial")
  if scenetree and scenetree.findClassObjects then
    for _, materialName in ipairs(scenetree.findClassObjects("Material") or {}) do
      if count >= cap then break end
      if matchesAny(string.lower(materialName), ROAD_WORDS) then add(materialName) end
    end
  end
  return targets
end

local function darkenColorString(value, multiplier)
  local r, g, b, a
  if value and value ~= "" then
    r, g, b, a = value:match("([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)%s*([%-%d%.eE]*)")
  end
  r, g, b, a = tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1
  return string.format("%g %g %g %g", r * multiplier, g * multiplier, b * multiplier, a)
end

local function wetMaterial(materialName, roughness)
  local material = scenetree and scenetree.findObject and scenetree.findObject(materialName)
  if not material then return end
  local layers = tonumber(material.activeLayers) or 1
  savedRoughness[materialName] = savedRoughness[materialName] or {}
  savedDiffuse[materialName] = savedDiffuse[materialName] or {}
  local darkness = 0.60 + 0.35 * clamp((roughness - 0.07) / 0.43, 0, 1)
  for layer = 0, layers - 1 do
    if savedRoughness[materialName][layer] == nil then savedRoughness[materialName][layer] = material:getField("roughnessFactor", layer) end
    if savedDiffuse[materialName][layer] == nil then savedDiffuse[materialName][layer] = material:getField("diffuseColor", layer) end
    pcall(function() material:setField("roughnessFactor", layer, tostring(roughness)) end)
    pcall(function() material:setField("diffuseColor", layer, darkenColorString(savedDiffuse[materialName][layer], darkness)) end)
  end
  pcall(function() material:reload() end)
end

local function dryMaterial(materialName)
  local material = scenetree and scenetree.findObject and scenetree.findObject(materialName)
  if not material then return end
  for layer, original in pairs(savedRoughness[materialName] or {}) do
    pcall(function() material:setField("roughnessFactor", layer, original ~= "" and tostring(original) or "1") end)
  end
  for layer, original in pairs(savedDiffuse[materialName] or {}) do
    pcall(function() material:setField("diffuseColor", layer, original ~= "" and original or "1 1 1 1") end)
  end
  pcall(function() material:reload() end)
end

local function queueWetLook(roughness)
  roughness = tonumber(roughness) or 0
  if globalSettings.vulkanSafeMode then roughness = 0 end
  -- Five useful wetness steps avoid repeatedly reloading every road material
  -- for visual differences that are too small to notice while driving.
  roughness = roughness > 0 and math.floor(roughness / 0.10 + 0.5) * 0.10 or 0
  if math.abs(roughness - wetTargetRoughness) < 0.001 then return end
  wetTargetRoughness = roughness
  wetMaterialQueue = {}
  local source = roughness > 0 and collectRoadMaterials() or savedRoughness
  for materialName in pairs(source) do wetMaterialQueue[#wetMaterialQueue + 1] = materialName end
end

local function tickWetLook(dt)
  if #wetMaterialQueue == 0 then return end
  wetMaterialTick = wetMaterialTick + math.max(0, tonumber(dt) or 0)
  if wetMaterialTick < wetMaterialTickSeconds then return end
  wetMaterialTick = wetMaterialTick - wetMaterialTickSeconds
  local materialName = table.remove(wetMaterialQueue)
  if wetTargetRoughness > 0 then wetMaterial(materialName, wetTargetRoughness) else dryMaterial(materialName) end
  if #wetMaterialQueue == 0 then
    wetAppliedRoughness = wetTargetRoughness
    if wetTargetRoughness == 0 then savedRoughness, savedDiffuse = {}, {} end
  end
end

local function updateWetLook()
  if not state or not state.settings.dynamicWeather or externalOverride or state.wetness <= 0.02 then
    queueWetLook(0)
    return
  end
  queueWetLook(lerp(0.50, 0.10, clamp(state.wetness, 0, 1)))
end

local function resolveSoundBase()
  if soundBase ~= nil then return soundBase ~= false and soundBase or nil end
  for _, candidate in ipairs({"/sounds/rls_weather/", "/sounds/", "sounds/"}) do
    if FS and FS.fileExists and FS:fileExists(candidate .. "jbw_rain2.ogg") then
      soundBase = candidate
      return candidate
    end
  end
  soundBase = false
  return nil
end

local function playWeatherSound(filename, volume, fadeIn)
  local base = resolveSoundBase()
  if not base or not Engine or not Engine.Audio or not Engine.Audio.playOnce then return nil end
  local ok, result = pcall(function()
    return Engine.Audio.playOnce("AudioGui", base .. filename, {volume = volume, fadeInTime = fadeIn or 0})
  end)
  return ok and result or nil
end

local function updateWeatherAudio(dt, effect, condition)
  local rainLevel = clamp((effect.rain or 0) / 3400, 0, 1)
  if rainLevel > 0.02 then
    audioRainTimer = audioRainTimer - dt
    if audioRainTimer <= 0 then
      local result = playWeatherSound("jbw_rain2.ogg", 0.35 + 0.20 * rainLevel, 0.35)
      audioRainTimer = result and result.len and result.len > 1 and (result.len - 0.35) or 7.5
    end
  else
    audioRainTimer = 0
  end

  if condition == "storm" and not transitioning then
    thunderCooldown = thunderCooldown - dt
    if thunderCooldown <= 0 then
      thunderCooldown = 5 + math.random() * 8
      thunderTimer = 0.4 + math.random() * 2.2
    end
  else
    thunderCooldown = 0
    thunderTimer = -1
  end
  if thunderTimer >= 0 then
    thunderTimer = thunderTimer - dt
    if thunderTimer < 0 then
      playWeatherSound("jbw_thunder" .. tostring(math.random(1, 3)) .. ".ogg", 0.80)
    end
  end
end

local function restoreGroundModels()
  if not baseline or not core_environment or not core_environment.groundModels or not be then return end
  for name, original in pairs(baseline.groundModels or {}) do
    local gm = core_environment.groundModels[name]
    if gm and gm.cdata then
      if original.staticFrictionCoefficient then gm.cdata.staticFrictionCoefficient = original.staticFrictionCoefficient end
      if original.slidingFrictionCoefficient then gm.cdata.slidingFrictionCoefficient = original.slidingFrictionCoefficient end
      if original.strength then gm.cdata.strength = original.strength end
      be:setGroundModel(name, gm.cdata)
    end
  end
  lastGripBucket = nil
end

local function restoreEnvironment()
  if not environmentApplied then
    clearRainObject("rlsDynamicWeatherRain")
    rainShown = 0
    return
  end
  if not baseline then
    clearRainObject("rlsDynamicWeatherRain")
    rainShown = 0
    return
  end
  setRain(0)
  if core_environment and core_environment.setFogDensity and baseline.fogDensity then core_environment.setFogDensity(baseline.fogDensity) end
  local info = levelInfo()
  if info and baseline.fogAtmosphereHeight then info.fogAtmosphereHeight = baseline.fogAtmosphereHeight end
  if info and baseline.temperatureCurveC and baseline.temperatureCurveC ~= "" then pcall(function() info:setField("temperatureCurveC", 0, baseline.temperatureCurveC) end) end
  local sky = scatterSky()
  if sky then
    if baseline.skyBrightness then sky.skyBrightness = baseline.skyBrightness end
    if baseline.sunScale then sky.sunScale = Point4F(baseline.sunScale[1], baseline.sunScale[2], baseline.sunScale[3], baseline.sunScale[4]) end
    if baseline.ambientScale then sky.ambientScale = Point4F(baseline.ambientScale[1], baseline.ambientScale[2], baseline.ambientScale[3], baseline.ambientScale[4]) end
    if baseline.colorize then sky.colorize = Point4F(baseline.colorize[1], baseline.colorize[2], baseline.colorize[3], baseline.colorize[4]) end
    if baseline.sunSize then sky.sunSize = baseline.sunSize end
    if baseline.flareScale then sky.flareScale = baseline.flareScale end
    if baseline.brightness then sky.brightness = baseline.brightness end
    pcall(function() sky:postApply() end)
  end
  restoreGroundModels()
  queueWetLook(0)
  if externalOverride and scenetree and scenetree.tod and baseline.timeOfDayPlay ~= nil then scenetree.tod.play = baseline.timeOfDayPlay end
  currentEffect = copyTable(EFFECTS.clear)
  transitioning = false
  environmentApplied = false
end

local EFFECT_KEYS = {"fogAdd", "sky", "sun", "ambient", "brightness", "wind"}

local function effectFor(condition, fogFactor, fog)
  local target = copyTable(EFFECTS[condition] or EFFECTS.clear)
  target.fogAdd = math.max(target.fogAdd or 0, fogFactor * (fog and fog.maxDensity or 0))
  return target
end

local function startTransition(condition, fogFactor, fog)
  local target = effectFor(condition, fogFactor, fog)
  effectFrom = copyTable(currentEffect)
  if not effectFrom.sky then effectFrom = copyTable(EFFECTS.clear) end
  effectTarget = target
  transitionElapsed = 0
  transitionDuration = clamp(profile.transitionMinutes * 1.5, 8, 45)
  transitioning = true
end

local function applyVisualEffect(effect, fog)
  captureBaseline()
  environmentApplied = true
  if core_environment and core_environment.setFogDensity then core_environment.setFogDensity((baseline.fogDensity or 0) + (effect.fogAdd or 0)) end
  local info = levelInfo()
  if info then
    local atmosphereHeight = fog and fog.atmosphereHeight or baseline.fogAtmosphereHeight
    if atmosphereHeight then info.fogAtmosphereHeight = atmosphereHeight end
  end
  local sky = scatterSky()
  if sky then
    sky.skyBrightness = (baseline.skyBrightness or 1) * (effect.sky or 1)
    if baseline.sunScale then sky.sunScale = Point4F(baseline.sunScale[1] * effect.sun, baseline.sunScale[2] * effect.sun, baseline.sunScale[3] * effect.sun, baseline.sunScale[4]) end
    if baseline.ambientScale then sky.ambientScale = Point4F(baseline.ambientScale[1] * effect.ambient, baseline.ambientScale[2] * effect.ambient, baseline.ambientScale[3] * effect.ambient, baseline.ambientScale[4]) end
    if baseline.colorize and effect.tint then sky.colorize = Point4F(baseline.colorize[1] * effect.tint[1], baseline.colorize[2] * effect.tint[2], baseline.colorize[3] * effect.tint[3], baseline.colorize[4]) end
    if baseline.sunSize then sky.sunSize = baseline.sunSize * effect.sun end
    if baseline.flareScale then sky.flareScale = baseline.flareScale * effect.sun end
    if baseline.brightness then sky.brightness = baseline.brightness * effect.brightness end
    pcall(function() sky:postApply() end)
  end
  setRain(effect.rain or 0)
end

local function wetnessBand()
  local bands = profile.wetness.bands or {0.25, 0.60, 0.85}
  if state.wetness < bands[1] then return 1 end
  if state.wetness < bands[2] then return 2 end
  if state.wetness < bands[3] then return 3 end
  return 4
end

local function temperatureMultiplier(surfaceTemp, highGrip)
  local amplitude = highGrip and (1 / 15) or 0.025
  if surfaceTemp <= 0 then return 1 - amplitude end
  if surfaceTemp < 20 then return lerp(1 - amplitude, 1, surfaceTemp / 20) end
  if surfaceTemp < 35 then return lerp(1, 1 + amplitude, (surfaceTemp - 20) / 15) end
  if surfaceTemp < 45 then return lerp(1 + amplitude, 1 + amplitude * 0.6, (surfaceTemp - 35) / 10) end
  return math.max(1 - amplitude * 0.4, 1 + amplitude * 0.6 - (surfaceTemp - 45) * amplitude / 25)
end

local function applyGroundGrip(condition)
  if not state.settings.dynamicWeather or externalOverride then restoreGroundModels(); return end
  captureBaseline()
  local surfaceTemp = surfaceTemperatureAt(state.dayIndex, state.minuteOfDay, condition)
  local tempBucket = math.floor(surfaceTemp / 5)
  local band = wetnessBand()
  local bucket = tostring(tempBucket) .. ":" .. tostring(band)
  if bucket == lastGripBucket then return end
  lastGripBucket = bucket
  environmentApplied = true
  local wetMultipliers = profile.wetness.gripMultipliers or {1, 0.98, 0.94, 0.90}
  local wetMultiplier = tonumber(wetMultipliers[band]) or 1
  for name, original in pairs(baseline.groundModels or {}) do
    local gm = core_environment.groundModels[name]
    if gm and gm.cdata and original.staticFrictionCoefficient and original.slidingFrictionCoefficient then
      local highGrip = original.staticFrictionCoefficient > 1.0
      local multiplier = wetMultiplier * temperatureMultiplier(surfaceTemp, highGrip)
      gm.cdata.staticFrictionCoefficient = original.staticFrictionCoefficient * multiplier
      gm.cdata.slidingFrictionCoefficient = original.slidingFrictionCoefficient * multiplier
      be:setGroundModel(name, gm.cdata)
    end
  end
end

local function getTireWeatherState()
  local result = {
    roadWetness = 0,
    wetGripMultipliers = {
      standard = 1.00,
      sport = 0.94,
      race = 0.80,
      drag = 0.72,
    },
    wetGroundModels = {},
  }

  local configured = profile and profile.wetness and profile.wetness.tireCompoundGripMultipliers
  for compound, fallback in pairs(result.wetGripMultipliers) do
    result.wetGripMultipliers[compound] = clamp(
      configured and tonumber(configured[compound]) or fallback, 0.10, 1)
  end

  if state and profile and worldReady then
    captureBaseline()
    for name in pairs(baseline and baseline.groundModels or {}) do
      result.wetGroundModels[tostring(name)] = true
    end
  end

  if state and state.settings and state.settings.dynamicWeather and not externalOverride then
    result.roadWetness = clamp(state.wetness, 0, 1)
  end
  return result
end

local function gameMinutesPerRealSecond(minute)
  local segmentGameMinutes, allocation
  if minute < 240 then segmentGameMinutes, allocation = 240, 4
  elseif minute < 420 then segmentGameMinutes, allocation = 180, 10
  elseif minute < 1020 then segmentGameMinutes, allocation = 600, 28
  elseif minute < 1200 then segmentGameMinutes, allocation = 180, 12
  else segmentGameMinutes, allocation = 240, 6 end
  local scale = state.settings.dayLengthMinutes / 60
  return segmentGameMinutes / (allocation * 60 * scale)
end

local function wetnessRate(condition)
  if not state.settings.dynamicWeather then return -(tonumber(profile.wetness.dryPerMinute) or 0.004) end
  condition = effectiveCondition(condition)
  if condition == "drizzle" then return tonumber(profile.wetness.drizzlePerMinute) or 0.003 end
  if condition == "rain" then return tonumber(profile.wetness.rainPerMinute) or 0.008 end
  if condition == "storm" then return tonumber(profile.wetness.stormPerMinute) or 0.015 end
  local surfaceTemp = surfaceTemperatureAt(state.dayIndex, state.minuteOfDay, condition)
  local dry = tonumber(profile.wetness.dryPerMinute) or 0.004
  local tempFactor = clamp(1 + (surfaceTemp - 20) * 0.02, 0.5, 1.5)
  local windFactor = 1 + ((EFFECTS[condition] and EFFECTS[condition].wind) or 0) * 0.2
  return -dry * tempFactor * windFactor
end

local function advanceMinutes(amount)
  local remaining = math.max(0, tonumber(amount) or 0)
  while remaining > 0 do
    local step = math.min(1, remaining)
    local condition = conditionAt(state.dayIndex, state.minuteOfDay)
    state.wetness = clamp(state.wetness + wetnessRate(condition) * step, 0, 1)
    state.minuteOfDay = state.minuteOfDay + step
    if state.minuteOfDay >= 1440 then
      state.minuteOfDay = state.minuteOfDay - 1440
      state.dayIndex = state.dayIndex + 1
      ensureHorizon()
    end
    remaining = remaining - step
  end
end

local function currentSnapshot()
  local rawCondition, segment, day, segmentIndex = conditionAt(state.dayIndex, state.minuteOfDay)
  local condition = effectiveCondition(rawCondition)
  local fogFactor, fog = fogFactorAt(day, state.minuteOfDay)
  local surfaceTemp, ambientTemp = surfaceTemperatureAt(state.dayIndex, state.minuteOfDay, condition)
  local meta = CONDITION_META[condition] or CONDITION_META.clear
  return {
    rawCondition = rawCondition,
    condition = condition,
    segment = segment,
    segmentIndex = segmentIndex,
    day = day,
    fogFactor = fogFactor,
    fog = fog,
    ambientTempC = ambientTemp,
    surfaceTempC = surfaceTemp,
    humidity = fogFactor > 0.05 and math.max(meta.humidity, 92) or meta.humidity,
    precipitationChance = meta.precipitation,
    windMph = math.floor(meta.windMph * globalSettings.visualWindScale + 0.5),
  }
end

local function formatCondition(name, fogFactor)
  if fogFactor and fogFactor > 0 then return "Morning Fog" end
  local labels = {clear="Clear", partlyCloudy="Partly Cloudy", overcast="Overcast", drizzle="Drizzle", rain="Rain", storm="Storm"}
  return labels[name] or name
end

local function daySummary(dayIndex)
  local day = findDay(dayIndex)
  if not day then return nil end
  local counts = {}
  for _, segment in ipairs(day.segments or {}) do
    local name = effectiveCondition(segment.condition)
    counts[name] = (counts[name] or 0) + (segment.endMinute - segment.startMinute)
  end
  local dominant, best = "clear", -1
  for name, minutes in pairs(counts) do if minutes > best then dominant, best = name, minutes end end
  local low, high = 1000, -1000
  for minute = 0, 1380, 60 do
    local t = temperatureAt(dayIndex, minute)
    low, high = math.min(low, t), math.max(high, t)
  end
  return {dayIndex = dayIndex, condition = dominant, label = formatCondition(dominant), lowC = low, highC = high, fog = day.fog ~= nil}
end

local function getUiState()
  if not state then return {ready = false} end
  ensureHorizon()
  local snapshot = currentSnapshot()
  local hourly = {}
  for i = 0, 11 do
    local absolute = state.minuteOfDay + i * 60
    local dayOffset = math.floor(absolute / 1440)
    local minute = absolute % 1440
    local raw, _, day = conditionAt(state.dayIndex + dayOffset, minute)
    local condition = effectiveCondition(raw)
    local ff = fogFactorAt(day, minute)
    hourly[#hourly + 1] = {
      dayOffset = dayOffset,
      minute = minute,
      condition = condition,
      label = formatCondition(condition, ff),
      temperatureC = temperatureAt(state.dayIndex + dayOffset, minute),
      precipitationChance = (CONDITION_META[condition] or CONDITION_META.clear).precipitation,
    }
  end
  local daily = {}
  for i = 0, 6 do daily[#daily + 1] = daySummary(state.dayIndex + i) end
  return {
    ready = true,
    mapId = getMapId(),
    location = profile.displayName,
    dayIndex = state.dayIndex,
    minuteOfDay = math.floor(state.minuteOfDay + 0.5),
    playCycle = state.playCycle,
    condition = snapshot.condition,
    conditionLabel = formatCondition(snapshot.condition, snapshot.fogFactor),
    fogFactor = snapshot.fogFactor,
    temperatureC = snapshot.ambientTempC,
    surfaceTemperatureC = snapshot.surfaceTempC,
    humidity = snapshot.humidity,
    precipitationChance = snapshot.precipitationChance,
    windMph = snapshot.windMph,
    wetness = math.floor(state.wetness * 100 + 0.5),
    externalOverride = externalOverride,
    missionFrozen = missionFrozen,
    travelJournalOverrideActive = travelJournalOverrideActive,
    settings = copyTable(state.settings),
    globalSettings = copyTable(globalSettings),
    hourly = hourly,
    daily = daily,
  }
end

local function pushUiState(force)
  if not guihooks or not guihooks.trigger or not state then return end
  local snapshot = getUiState()
  local signature = table.concat({snapshot.dayIndex, snapshot.minuteOfDay, snapshot.condition, snapshot.wetness, tostring(snapshot.externalOverride), tostring(snapshot.missionFrozen)}, ":")
  if force or signature ~= lastUiSignature then
    lastUiSignature = signature
    guihooks.trigger("RLSWeatherState", snapshot)
  end
end

local function fireForecastNotification(snapshot)
  if not state.settings.forecastNotifications or externalOverride then return end
  if not ui_phone_layout and extensions and extensions.load then pcall(extensions.load, "ui_phone_layout") end
  if not ui_phone_layout or not ui_phone_layout.fireNotification then return end
  local segment = snapshot.segment
  if not segment then return end
  local remaining = segment.endMinute - state.minuteOfDay
  if remaining > 60 or remaining < 0 then return end
  local nextCondition = snapshot.day.segments[snapshot.segmentIndex + 1]
  if not nextCondition then
    local tomorrow = findDay(state.dayIndex + 1)
    nextCondition = tomorrow and tomorrow.segments and tomorrow.segments[1]
  end
  if not nextCondition then return end
  local nextEffective = effectiveCondition(nextCondition.condition)
  local channel, title, message
  if nextEffective == "rain" or nextEffective == "drizzle" then
    channel, title, message = "weather.rainSoon", "Rain approaching", "Wet weather is expected within the next hour."
  elseif nextEffective == "storm" then
    channel, title, message = "weather.stormSoon", "Storm approaching", "A storm is expected within the next hour."
  end
  local key = channel and table.concat({state.dayIndex, snapshot.segmentIndex, channel}, ":")
  if key and not notificationHistory[key] then
    notificationHistory[key] = true
    ui_phone_layout.fireNotification(channel, {title = title, message = message, kind = "warning", ttl = 8, source = "Weather"})
  end
  local fog = snapshot.day.fog
  if fog and state.minuteOfDay < fog.startMinute and fog.startMinute - state.minuteOfDay <= 60 then
    key = table.concat({state.dayIndex, "fog"}, ":")
    if not notificationHistory[key] then
      notificationHistory[key] = true
      ui_phone_layout.fireNotification("weather.fogSoon", {title = "Fog forming", message = "Dense morning fog is expected within the next hour.", kind = "warning", ttl = 8, source = "Weather"})
    end
  end
end

local function updateCondition(force)
  if not state then return end
  if externalOverride then
    pushUiState(force)
    return
  end
  local snapshot = currentSnapshot()
  currentConditionName = snapshot.condition
  local conditionKey = table.concat({snapshot.condition, math.floor(snapshot.fogFactor * 10), tostring(globalSettings.vulkanSafeMode)}, ":")
  if force or conditionKey ~= lastConditionKey then
    lastConditionKey = conditionKey
    startTransition(snapshot.condition, snapshot.fogFactor, snapshot.fog)
  end
  applyGroundGrip(snapshot.condition)
  updateWetLook()
  fireForecastNotification(snapshot)
  pushUiState(force)
end

local function applyCurrentConditionImmediately()
  if not state or externalOverride or not state.settings.dynamicWeather then return end
  local snapshot = currentSnapshot()
  currentConditionName = snapshot.condition
  currentEffect = effectFor(snapshot.condition, snapshot.fogFactor, snapshot.fog)
  effectFrom = copyTable(currentEffect)
  effectTarget = copyTable(currentEffect)
  transitionElapsed = 0
  transitionDuration = 0
  transitioning = false
  applyVisualEffect(currentEffect, snapshot.fog)
end

local function saveState(currentSavePath)
  if not state then return false end
  currentSavePath = currentSavePath or getSavePath()
  if not currentSavePath then return false end
  local dir = currentSavePath .. "/career/rls_career"
  ensureDirectory(dir)
  state.version = schemaVersion
  state.generatorVersion = generatorVersion
  local ok = writeJson(currentSavePath .. saveRelativePath, state)
  writeJson(currentSavePath .. legacyTimeRelativePath, {time = minuteToEngineTime(state.minuteOfDay), play = state.playCycle})
  return ok
end

local function loadState()
  loadGlobalSettings()
  local path = getSavePath()
  local raw = path and jsonReadFile(path .. saveRelativePath) or nil
  if not raw and path then
    local legacy = jsonReadFile(path .. legacyTimeRelativePath)
    if legacy then
      raw = defaultState()
      raw.minuteOfDay = engineTimeToMinute(legacy.time)
      raw.playCycle = legacy.play ~= false
    end
  end
  state = normalizeState(raw)
  notificationHistory = {}
  state.activeMap = getMapId()
  loadProfile()
  ensureHorizon()
  loaded = true
end

local function showExternalWarning()
  if externalWarningShown or not guihooks then return end
  externalWarningShown = true
  guihooks.trigger("toastrMsg", {
    type = "error",
    title = "External Weather Control",
    msg = "JayBeam Dynamic Weather has priority. RLS Weather is paused.",
  })
end

local function checkExternalOverride()
  local loadedNow = extensions and extensions.isExtensionLoaded and extensions.isExtensionLoaded("jbWeather") or false
  if loadedNow == externalOverride then
    if loadedNow then showExternalWarning() end
    return
  end
  externalOverride = loadedNow
  if externalOverride then
    restoreEnvironment()
    lastExternalMinute = scenetree and scenetree.tod and engineTimeToMinute(scenetree.tod.time) or state.minuteOfDay
    showExternalWarning()
  else
    local orphan = scenetree and scenetree.findObject and scenetree.findObject("jbWeatherRain")
    if orphan then orphan:delete() end
    restoreGroundModels()
    lastExternalMinute = nil
    lastConditionKey = nil
    updateCondition(true)
  end
  pushUiState(true)
end

local function syncExternalClock()
  if not externalOverride or not scenetree or not scenetree.tod then return end
  local minute = engineTimeToMinute(scenetree.tod.time)
  if lastExternalMinute and minute + 720 < lastExternalMinute then
    state.dayIndex = state.dayIndex + 1
    ensureHorizon()
  end
  state.minuteOfDay = minute
  lastExternalMinute = minute
end

local function applyTimeOfDay()
  if not state or not scenetree or not scenetree.tod or externalOverride then return end
  local engineTime = minuteToEngineTime(state.minuteOfDay)
  if scenetree.tod.play then scenetree.tod.play = false end
  if lastAppliedTimeOfDay ~= engineTime then
    scenetree.tod.time = engineTime
    lastAppliedTimeOfDay = engineTime
  end
end

-- Stock Ctrl+Shift+D calls core_environment.cycleTimeOfDay, but applyTimeOfDay()
-- owns scenetree.tod while career is active and would snap it back next frame.
-- Only Freeroam+ (cheats) / valid devkey may cycle; everyone else gets a no-op
-- so normal career can't skip the weather clock.
local stockCycleTimeOfDay = nil

local function canCycleTimeOfDay()
  if career_modules_cheats and career_modules_cheats.isCheatsMode and career_modules_cheats.isCheatsMode() then
    return true
  end
  if overhaul_extensionManager and overhaul_extensionManager.isDevKeyValid and overhaul_extensionManager.isDevKeyValid() then
    return true
  end
  return false
end

local function cycleTimeOfDay(...)
  if not careerActive or not loaded or not state or externalOverride then
    if stockCycleTimeOfDay then
      return stockCycleTimeOfDay(...)
    end
    return
  end

  if not canCycleTimeOfDay() then
    return
  end

  local t = minuteToEngineTime(state.minuteOfDay)
  if t < 0.2 then
    t = 0.23
  elseif t >= 0.5 then
    t = 0.05
  else
    t = 0.5
  end

  -- Keep RLS weather clock in sync with the sky (same day/night/sunrise steps as stock).
  state.minuteOfDay = engineTimeToMinute(t)
  ensureHorizon()
  lastConditionKey = nil
  applyTimeOfDay()
  updateCondition(true)
  saveState()
  pushUiState(true)
end

local function installCycleTimeOfDayHook()
  if not core_environment or stockCycleTimeOfDay then return end
  stockCycleTimeOfDay = core_environment.cycleTimeOfDay
  core_environment.cycleTimeOfDay = cycleTimeOfDay
end

local function uninstallCycleTimeOfDayHook()
  if core_environment and stockCycleTimeOfDay then
    core_environment.cycleTimeOfDay = stockCycleTimeOfDay
  end
  stockCycleTimeOfDay = nil
end

local function onUpdate(dtReal, dtSim)
  if not careerActive or not worldReady or not loaded or not state then return end
  if travelJournalOverrideActive then return end
  local dt = tonumber(dtSim) or 0
  tickWetLook(dtReal)
  stateTick = stateTick + math.max(0, dt)
  visualTick = visualTick + math.max(0, dt)

  if stateTick >= stateTickSeconds then
    stateTick = stateTick - stateTickSeconds
    checkExternalOverride()
    if externalOverride then
      syncExternalClock()
    elseif state.playCycle and not missionFrozen then
      advanceMinutes(stateTickSeconds * gameMinutesPerRealSecond(state.minuteOfDay))
    end
    updateCondition(false)
  end

  if not missionFrozen and not externalOverride and state.settings.dynamicWeather and transitioning then
    transitionElapsed = transitionElapsed + dt
    local p = clamp(transitionElapsed / math.max(0.01, transitionDuration), 0, 1)
    for _, key in ipairs(EFFECT_KEYS) do currentEffect[key] = lerp(effectFrom[key] or effectTarget[key], effectTarget[key], p) end
    currentEffect.rain = p >= 0.35 and effectTarget.rain or (effectFrom.rain or 0)
    currentEffect.wetRough = effectTarget.wetRough
    currentEffect.tint = {
      lerp((effectFrom.tint or {1,1,1})[1], effectTarget.tint[1], p),
      lerp((effectFrom.tint or {1,1,1})[2], effectTarget.tint[2], p),
      lerp((effectFrom.tint or {1,1,1})[3], effectTarget.tint[3], p),
    }
    if visualTick >= visualTickSeconds or p >= 1 then
      visualTick = 0
      applyVisualEffect(currentEffect, currentSnapshot().fog)
    end
    if p >= 1 then transitioning = false end
  elseif not state.settings.dynamicWeather and environmentApplied then
    restoreEnvironment()
  end

  if not missionFrozen and not externalOverride and state.settings.dynamicWeather then
    updateWeatherAudio(math.max(0, dt), currentEffect, currentConditionName)
  end

  applyTimeOfDay()
end

local function setSetting(key, value)
  if not state then return false end
  if key == "temperatureUnit" then
    globalSettings.temperatureUnit = value == "C" and "C" or "F"
    saveGlobalSettings()
  elseif key == "visualWindScale" then
    globalSettings.visualWindScale = clamp(tonumber(value) or 1, 0, 2)
    saveGlobalSettings()
  elseif key == "dynamicWeather" then
    state.settings.dynamicWeather = value == true
    if not state.settings.dynamicWeather then state.wetness = 0; restoreEnvironment() end
    lastConditionKey = nil
  elseif key == "allowRainyDays" then
    state.settings.allowRainyDays = value == true
    lastConditionKey = nil
  elseif key == "dayLengthMinutes" then
    local number = tonumber(value)
    if not ({[30]=true,[45]=true,[60]=true,[90]=true,[120]=true})[number] then return false end
    state.settings.dayLengthMinutes = number
  elseif key == "forecastNotifications" then
    state.settings.forecastNotifications = value == true
  else
    return false
  end
  updateCondition(true)
  saveState()
  return true
end

local function sleepTo(engineTime)
  if not state or externalOverride then return false end
  local target = engineTimeToMinute(engineTime)
  local delta = target - state.minuteOfDay
  if delta <= 0 then delta = delta + 1440 end
  advanceMinutes(delta)
  state.minuteOfDay = target
  ensureHorizon()
  lastConditionKey = nil
  applyTimeOfDay()
  updateCondition(true)
  saveState()
  return true
end

local function onBeforeCareerLevelSwitch(currentMap, nextMap)
  if not state or not nextMap or nextMap == currentMap then return end
  advanceMinutes(travelMinutes)
  state.forecastEpoch = state.forecastEpoch + 1
  state.activeMap = nextMap
  state.horizon = {}
  local previousProfile = profile
  local override = jsonReadFile("/levels/" .. nextMap .. "/rls_weather.json")
  local defaultProfile = jsonReadFile("/gameplay/rls_weather/default.json") or {}
  profile = deepMerge(defaultProfile, override or {})
  profile.displayName = profile.displayName or nextMap
  profile.conditionWeights = profile.conditionWeights or {}
  profile.conditionDurationsMinutes = profile.conditionDurationsMinutes or {}
  profile.morningFog = profile.morningFog or {}
  profile.temperatureCurveC = profile.temperatureCurveC or {{0, 13}, {720, 23}, {1440, 13}}
  profile.dailyTemperatureVarianceC = tonumber(profile.dailyTemperatureVarianceC) or 2.5
  profile.wetness = profile.wetness or {}
  ensureHorizon()
  state.wetness = 0
  local elapsed = state.minuteOfDay
  state.minuteOfDay = 0
  advanceMinutes(elapsed)
  profile = profile or previousProfile
  saveState()
end

local function resetWorldRuntime()
  worldReady = true
  loaded = false
  initializedMapId = nil
  travelJournalOverrideActive = false
  externalWarningShown = false
  baseline = nil
  environmentApplied = false
  savedRoughness, savedDiffuse, wetMaterialQueue = {}, {}, {}
  wetTargetRoughness, wetAppliedRoughness = 0, 0
  wetMaterialTick = 0
  currentConditionName = "clear"
  lastAppliedTimeOfDay = nil
  soundBase = nil
  lastGripBucket = nil
  lastConditionKey = nil
end

local function initializeCurrentWorld(forceReset)
  local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if type(mapId) ~= "string" or mapId == "" then return false end

  if forceReset or not worldReady or (initializedMapId and initializedMapId ~= mapId) then
    resetWorldRuntime()
  end
  worldReady = true
  if not careerActive then return false end

  installCycleTimeOfDayHook()
  if loaded and state and initializedMapId == mapId then
    pushUiState(true)
    return true
  end

  loadState()
  initializedMapId = mapId
  checkExternalOverride()
  applyTimeOfDay()
  if not externalOverride then
    updateCondition(true)
    -- Enter career with the current forecast already reflected in the world.
    -- Transitions remain gradual for later weather changes.
    applyCurrentConditionImmediately()
  end
  return true
end

local function onCareerActive(active)
  careerActive = active == true
  if not careerActive then
    travelJournalOverrideActive = false
    uninstallCycleTimeOfDayHook()
    restoreEnvironment()
    loaded = false
    initializedMapId = nil
  else
    -- Career modules are commonly loaded after onWorldReadyState(2) during map
    -- travel. Initialize immediately when the destination world already exists.
    initializeCurrentWorld(false)
  end
end

local function onWorldReadyState(value)
  if value ~= 2 then return end
  careerActive = career_career and career_career.isActive and career_career.isActive() == true
  initializeCurrentWorld(true)
end

local function onClientStartMission()
  worldReady = false
  loaded = false
  initializedMapId = nil
  baseline = nil
  environmentApplied = false
  externalWarningShown = false
  missionFrozen = false
  travelJournalOverrideActive = false
  stateTick = 0
  visualTick = 0
  wetMaterialTick = 0
  currentConditionName = "clear"
  lastAppliedTimeOfDay = nil
  rainShown = 0
  currentEffect = copyTable(EFFECTS.clear)
  savedRoughness, savedDiffuse, wetMaterialQueue = {}, {}, {}
  wetTargetRoughness, wetAppliedRoughness = 0, 0
  clearRainObject("rlsDynamicWeatherRain")
end

local function onClientEndMission()
  restoreEnvironment()
  travelJournalOverrideActive = false
  worldReady = false
  loaded = false
  initializedMapId = nil
  baseline = nil
end

local function onAnyMissionChanged(status, mission)
  if not mission then return end
  if status == "started" then missionFrozen = true
  elseif status == "stopped" then missionFrozen = false end
  pushUiState(true)
end

local function getDayNightCycle()
  if externalOverride and scenetree and scenetree.tod then return {play = scenetree.tod.play, time = scenetree.tod.time} end
  if not state then return {play = false, time = 0} end
  return {play = state.playCycle, time = minuteToEngineTime(state.minuteOfDay)}
end

local function toggleDayNightCycle(value)
  if externalOverride then
    if scenetree and scenetree.tod then scenetree.tod.play = value == true end
    return true
  end
  if not state then return false end
  state.playCycle = value == true
  saveState()
  pushUiState(true)
  return true
end

local function requestUiState()
  pushUiState(true)
  return getUiState()
end

local function setTravelJournalOverrideActive(active)
  travelJournalOverrideActive = active == true
  stateTick = 0
  visualTick = 0
  pushUiState(true)
  return true
end

local function onExtensionUnloaded()
  travelJournalOverrideActive = false
  uninstallCycleTimeOfDayHook()
  restoreEnvironment()
end

M.getUiState = getUiState
M.requestUiState = requestUiState
M.getTireWeatherState = getTireWeatherState
M.setSetting = setSetting
M.getClockState = getDayNightCycle
M.getDayNightCycle = getDayNightCycle
M.toggleDayNightCycle = toggleDayNightCycle
M.sleepTo = sleepTo
M.cycleTimeOfDay = cycleTimeOfDay
M.isExternalOverrideActive = function() return externalOverride end
M.setTravelJournalOverrideActive = setTravelJournalOverrideActive
M.onBeforeCareerLevelSwitch = onBeforeCareerLevelSwitch
M.onCareerActive = onCareerActive
M.onCareerActivated = function() onCareerActive(true) end
M.onWorldReadyState = onWorldReadyState
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onSaveCurrentProfile = saveState
M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded

return M
