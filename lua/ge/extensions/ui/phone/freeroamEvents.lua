local M = {}
M.dependencies = { 'career_modules_inventory', 'gameplay_events_freeroamEvents' }

local logTag = 'ui_phone_freeroamEvents'
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
local freeroamUtils = require('gameplay/events/freeroam/utils')
local burnoutConfig = require('gameplay/events/freeroam/burnoutConfig')
local DEMO_CONFIG_FILENAME = "demo.config.json"
local mNavTargets = {}

local BURNOUT_EVENTS_BY_LEVEL = {
  west_coast_usa = {
    {
      eventId = "burnout_fastAuto",
      zoneId = "fastAuto",
      label = "Fast Automotive Burnout Pad",
      types = {"burnout", "freeroam"},
      triggerName = "rls_burnoutTestZone_fastAuto",
      thumbnail = "/levels/west_coast_usa/facilities/freeroamEvents/burnout_fastAuto.jpg",
      reward = 240,
      scoreGoal = 6000,
    },
  },
}

local function getCurrentLevel()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename and getMissionFilename() ~= '' then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function loadRaceData()
  local level = getCurrentLevel()
  if not level or level == '' then
    log('D', logTag, "loadRaceData: no level identifier")
    return {}
  end
  local filePath = "levels/" .. level .. "/race_data.json"
  local raceData = jsonReadFile(filePath)
  local fromFile = raceData ~= nil
  raceData = raceData or { races = {} }
  local races = raceData.races or {}
  local count = 0
  for _ in pairs(races) do count = count + 1 end
  log('D', logTag, string.format("loadRaceData: path=%s, fileRead=%s, races=%d", filePath, tostring(fromFile), count))
  return races
end

local function loadDemoConfig(level)
  if not level or level == '' then
    return nil
  end
  local filePath = "levels/" .. level .. "/" .. DEMO_CONFIG_FILENAME
  local data = jsonReadFile(filePath)
  if type(data) ~= "table" then
    return nil
  end
  return data
end

local function loadDemoSites(level, sitesFile)
  if not level or level == '' then
    return nil
  end
  local fileName = (type(sitesFile) == "string" and sitesFile ~= "") and sitesFile or "demolition.sites.json"
  local filePath = "levels/" .. level .. "/" .. fileName
  local data = jsonReadFile(filePath)
  if type(data) ~= "table" then
    return nil
  end
  return data
end

local function decorateBurnoutEventForUi(event, level)
  local out = {}
  for key, value in pairs(event) do
    out[key] = value
  end
  out.thumbnail = event.thumbnail or (level and ("/levels/" .. level .. "/facilities/freeroamEvents/" .. event.eventId .. ".jpg") or nil)
  return out
end

local function loadBurnoutConfigAndSites(level)
  local data = burnoutConfig.loadLevelData(level)
  local events = {}
  for _, event in ipairs(data.events or {}) do
    table.insert(events, decorateBurnoutEventForUi(event, level))
  end
  return events, data.sites
end

local function shallowMerge(base, override)
  local out = {}
  if type(base) == "table" then
    for k, v in pairs(base) do
      out[k] = v
    end
  end
  if type(override) == "table" then
    for k, v in pairs(override) do
      out[k] = v
    end
  end
  return out
end

local function getDistanceFromPlayer(playerPos, worldPos)
  if not playerPos or not worldPos then
    return -1
  end
  return math.floor((worldPos - playerPos):length())
end

local function getZoneByName(sitesData, zoneName)
  if type(zoneName) ~= "string" or zoneName == "" then
    return nil
  end
  if type(sitesData) ~= "table" or type(sitesData.zones) ~= "table" then
    return nil
  end
  for _, zone in ipairs(sitesData.zones) do
    if type(zone) == "table" and zone.name == zoneName then
      return zone
    end
  end
  return nil
end

local function getZoneCentroid(zone)
  if type(zone) ~= "table" or type(zone.vertices) ~= "table" or #zone.vertices < 3 then
    return nil
  end
  local sx, sy, sz = 0, 0, 0
  local count = 0
  for _, v in ipairs(zone.vertices) do
    if type(v) == "table" then
      sx = sx + (tonumber(v[1]) or 0)
      sy = sy + (tonumber(v[2]) or 0)
      sz = sz + (tonumber(v[3]) or 0)
      count = count + 1
    end
  end
  if count <= 0 then
    return nil
  end
  return vec3(sx / count, sy / count, sz / count)
end

local function getParkingSpotByName(sitesData, spotName)
  if type(spotName) ~= "string" or spotName == "" then
    return nil
  end
  if type(sitesData) ~= "table" or type(sitesData.parkingSpots) ~= "table" then
    return nil
  end
  for _, spot in ipairs(sitesData.parkingSpots) do
    if type(spot) == "table" and spot.name == spotName then
      return spot
    end
  end
  return nil
end

local function findDemoEventWorldPos(eventKey, eventCfg, sitesData)
  local spotName = type(eventCfg) == "table" and eventCfg.startSpotName or nil
  if type(spotName) ~= "string" or spotName == "" then
    spotName = "start_" .. tostring(eventKey or "")
  end
  local startSpot = getParkingSpotByName(sitesData, spotName)
  if type(startSpot) == "table" and type(startSpot.pos) == "table" then
    local x = tonumber(startSpot.pos[1])
    local y = tonumber(startSpot.pos[2])
    local z = tonumber(startSpot.pos[3])
    if x and y and z then
      return vec3(x, y, z)
    end
  end

  local startObj = scenetree.findObject("fre_start_" .. eventKey)
  if startObj then
    return startObj:getPosition()
  end

  local stagingObj = scenetree.findObject("fre_staging_" .. eventKey)
  if stagingObj then
    return stagingObj:getPosition()
  end

  local suffix = tostring(eventKey):match("^demo_(.+)$")
  if suffix then
    local suffixStagingObj = scenetree.findObject("fre_staging_demo_" .. suffix)
    if suffixStagingObj then
      return suffixStagingObj:getPosition()
    end
  end

  local zoneName = type(eventCfg) == "table" and eventCfg.playZone or nil
  local zone = getZoneByName(sitesData, zoneName)
  return getZoneCentroid(zone)
end

local DEMO_TYPE_ALIASES = {
  demo = true,
  demolition = true,
  demolitionderby = true,
}

local function normalizeTypeToken(value)
  if type(value) ~= "string" then
    return nil
  end
  return string.lower(value)
end

local function hasType(types, expected)
  if type(types) ~= "table" then
    return false
  end
  local expectedNorm = normalizeTypeToken(expected)
  if not expectedNorm then
    return false
  end
  local expectedIsDemo = DEMO_TYPE_ALIASES[expectedNorm] == true
  for _, t in ipairs(types) do
    local token = normalizeTypeToken(t)
    if token == expectedNorm then
      return true
    end
    if expectedIsDemo and DEMO_TYPE_ALIASES[token] then
      return true
    end
  end
  return false
end

local function buildDemoStatsFromEntry(entry)
  entry = type(entry) == "table" and entry or {}
  local runs = math.max(0, math.floor(tonumber(entry.demoRuns) or 0))
  return {
    runs = runs,
    wins = math.max(0, math.floor(tonumber(entry.demoWins) or 0)),
    podiums = math.max(0, math.floor(tonumber(entry.demoPodiums) or 0)),
    averagePlacement = tonumber(entry.demoAveragePlacement) or 0,
    podiumRate = tonumber(entry.demoPodiumRate) or 0,
    fastestEliminationTime = tonumber(entry.demoFastestEliminationTime) or nil,
    averageSurvivalTime = tonumber(entry.demoAverageSurvivalTime) or 0,
    longestSurvivalTime = tonumber(entry.demoLongestSurvivalTime) or 0,
  }
end

local function hasDemoStats(stats)
  return type(stats) == "table" and math.max(0, math.floor(tonumber(stats.runs) or 0)) > 0
end

local function collectVehicleRecordsForLabel(allVehicles, raceLabel, isDemoEvent)
  local vehicleRecords = {}
  for invId, vehData in pairs(allVehicles or {}) do
    local entry = leaderboardManager.getLeaderboardEntry(invId, raceLabel) or {}
    local demoStats = buildDemoStatsFromEntry(entry)
    if entry.time or entry.driftScore or entry.topSpeed or (isDemoEvent and hasDemoStats(demoStats)) then
      local vehicleName = "Unknown Vehicle"
      if vehData then
        if vehData.niceName then
          vehicleName = vehData.niceName
        elseif vehData.model then
          vehicleName = vehData.model
        end
        if vehData.configName and vehData.configName ~= "" then
          vehicleName = vehicleName .. " " .. vehData.configName
        end
      end
      table.insert(vehicleRecords, {
        inventoryId = invId,
        vehicleName = vehicleName,
        time = entry.time,
        driftScore = entry.driftScore,
        topSpeed = entry.topSpeed,
        damagePercentage = entry.damagePercentage,
        demoStats = demoStats,
      })
    end
  end
  if isDemoEvent then
    table.sort(vehicleRecords, function(a, b)
      local sa = a.demoStats or {}
      local sb = b.demoStats or {}
      local wa = tonumber(sa.wins) or 0
      local wb = tonumber(sb.wins) or 0
      if wa ~= wb then return wa > wb end
      local pa = tonumber(sa.podiumRate) or 0
      local pb = tonumber(sb.podiumRate) or 0
      if pa ~= pb then return pa > pb end
      local aa = tonumber(sa.averagePlacement) or math.huge
      local ab = tonumber(sb.averagePlacement) or math.huge
      if aa ~= ab then return aa < ab end
      return tostring(a.vehicleName or "") < tostring(b.vehicleName or "")
    end)
  else
    table.sort(vehicleRecords, function(a, b)
      if a.time and b.time then return a.time < b.time end
      if a.time then return true end
      if b.time then return false end
      return false
    end)
  end
  return vehicleRecords
end

local function appendDemoEvents(events, levelId, playerPos, allVehicles, currentVehicleId, currentVehicleName)
  local demoCfg = loadDemoConfig(levelId)
  if type(demoCfg) ~= "table" or type(demoCfg.events) ~= "table" then
    return
  end

  local demoSites = loadDemoSites(levelId, demoCfg.sitesFile)
  local defaults = type(demoCfg.defaults) == "table" and demoCfg.defaults or {}

  for eventKey, rawEvent in pairs(demoCfg.events) do
    local merged = shallowMerge(defaults, type(rawEvent) == "table" and rawEvent or {})
    local label = merged.label or eventKey
    local worldPos = findDemoEventWorldPos(eventKey, merged, demoSites)
    local pos = nil
    local distance = -1
    if worldPos then
      pos = { x = worldPos.x, y = worldPos.y, z = worldPos.z }
      distance = getDistanceFromPlayer(playerPos, worldPos)
      mNavTargets[eventKey] = vec3(worldPos.x, worldPos.y, worldPos.z)
    end

    local currentVehicleBestTime = nil
    local currentVehicleDemoStats = nil
    if currentVehicleId then
      local bestEntry = leaderboardManager.getLeaderboardEntry(currentVehicleId, label) or {}
      currentVehicleBestTime = bestEntry.time
      currentVehicleDemoStats = buildDemoStatsFromEntry(bestEntry)
    end

    local thumbnail = "/levels/" .. levelId .. "/facilities/freeroamEvents/" .. eventKey .. ".jpg"
    local reward = tonumber(merged.reward) or 0
    local types = merged.type
    if type(types) ~= "table" or #types == 0 then
      types = { "demo" }
    end
    local isDemoEvent = hasType(types, "demo")

    local existing = events[eventKey]
    if existing then
      existing.label = existing.label or label
      existing.types = types
      existing.isDemoEvent = isDemoEvent
      existing.reward = existing.reward or reward
      existing.bestTime = nil
      existing.hotlap = false
      existing.hasDamageFactor = false
      existing.damageFactor = 0
      existing.hasTopSpeed = false
      existing.topSpeedGoal = nil
      existing.hasDrift = false
      existing.driftGoal = nil
      existing.hasAltRoute = false
      existing.altRouteLabel = nil
      existing.altRouteBestTime = nil
      existing.altRouteReward = nil
      existing.position = existing.position or pos
      if existing.position and (existing.distance == nil or existing.distance < 0) and worldPos then
        existing.distance = distance
      elseif existing.distance == nil then
        existing.distance = distance
      end
      existing.thumbnail = existing.thumbnail or thumbnail
      existing.currentVehicleBestTime = currentVehicleBestTime
      existing.demoStats = currentVehicleDemoStats
      existing.currentVehicleName = currentVehicleName
      existing.vehicleRecords = collectVehicleRecordsForLabel(allVehicles, label, isDemoEvent)
    else
      events[eventKey] = {
        raceName = eventKey,
        label = label,
        types = types,
        isDemoEvent = isDemoEvent,
        bestTime = nil,
        reward = reward,
        hotlap = false,
        hasDamageFactor = false,
        damageFactor = 0,
        hasTopSpeed = false,
        topSpeedGoal = nil,
        hasDrift = false,
        driftGoal = nil,
        hasAltRoute = false,
        altRouteLabel = nil,
        altRouteBestTime = nil,
        altRouteReward = nil,
        position = pos,
        distance = distance,
        thumbnail = thumbnail,
        currentVehicleBestTime = currentVehicleBestTime,
        demoStats = currentVehicleDemoStats,
        currentVehicleName = currentVehicleName,
        vehicleRecords = collectVehicleRecordsForLabel(allVehicles, label, isDemoEvent),
      }
    end
  end
end

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then return veh:getPosition() end
  return nil
end

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local function getVehicleDisplayName(vehData)
  if not vehData then return "Unknown Vehicle" end
  local name = ""
  if vehData.niceName then
    name = vehData.niceName
  elseif vehData.model then
    name = vehData.model
  end
  if vehData.configName and vehData.configName ~= "" then
    name = name .. " " .. vehData.configName
  end
  return name ~= "" and name or "Unknown Vehicle"
end

local function getBurnoutDefinitions(levelId)
  local byEventId = {}
  for _, event in ipairs(BURNOUT_EVENTS_BY_LEVEL[levelId] or {}) do
    byEventId[event.eventId] = event
  end
  local configuredEvents = loadBurnoutConfigAndSites(levelId)
  for _, event in ipairs(configuredEvents) do
    byEventId[event.eventId] = event
  end
  local events = {}
  for _, event in pairs(byEventId) do
    table.insert(events, event)
  end
  table.sort(events, function(a, b) return tostring(a.eventId) < tostring(b.eventId) end)
  return events
end

local function getBurnoutDefinitionByEventId(eventId, levelId)
  for _, event in ipairs(getBurnoutDefinitions(levelId or getCurrentLevel() or "")) do
    if event.eventId == eventId then
      return event
    end
  end
  return nil
end

local function buildVehicleRecords(allVehicles, eventLabel)
  local vehicleRecords = {}
  for invId, vehData in pairs(allVehicles or {}) do
    local entry = leaderboardManager.getLeaderboardEntry(invId, eventLabel) or {}
    if entry.time or entry.driftScore or entry.topSpeed then
      table.insert(vehicleRecords, {
        inventoryId = invId,
        vehicleName = getVehicleDisplayName(vehData),
        time = entry.time,
        driftScore = entry.driftScore,
        topSpeed = entry.topSpeed,
        damagePercentage = entry.damagePercentage,
      })
    end
  end

  table.sort(vehicleRecords, function(a, b)
    if a.driftScore and b.driftScore then return a.driftScore > b.driftScore end
    if a.driftScore then return true end
    if b.driftScore then return false end
    if a.topSpeed and b.topSpeed then return a.topSpeed > b.topSpeed end
    if a.topSpeed then return true end
    if b.topSpeed then return false end
    if a.time and b.time then return a.time < b.time end
    if a.time then return true end
    if b.time then return false end
    return false
  end)

  return vehicleRecords
end

local function getBurnoutDisplayReward(burnoutEvent)
  local baseReward = tonumber(burnoutEvent.reward) or 0
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return baseReward
  end
  if not freeroamUtils or not freeroamUtils.driftReward then
    return baseReward
  end
  local scoreGoal = tonumber(burnoutEvent.scoreGoal or burnoutEvent.driftGoal) or 6000
  local driftTargetTime = tonumber(burnoutEvent.driftTargetTime) or 60
  local bestTime = tonumber(burnoutEvent.bestTime) or driftTargetTime
  if driftTargetTime <= 0 then
    driftTargetTime = 60
  end
  if bestTime <= 0 then
    bestTime = 60
  end
  local raceStub = {
    label = burnoutEvent.label,
    type = burnoutEvent.types,
    burnoutComp = true,
    driftGoal = scoreGoal,
    driftTargetTime = driftTargetTime,
    bestTime = bestTime,
    reward = baseReward,
  }
  return math.floor((freeroamUtils.driftReward(raceStub, bestTime, scoreGoal) or baseReward) + 0.5)
end

local function addBurnoutEvents(events, levelId, currentVehicleId, currentVehicleName, allVehicles, playerPos)
  local _, sites = loadBurnoutConfigAndSites(levelId)
  for _, burnoutEvent in ipairs(getBurnoutDefinitions(levelId)) do
    local pos = nil
    local distance = -1
    local startObj = burnoutEvent.triggerName and scenetree.findObject(burnoutEvent.triggerName) or nil
    if startObj then
      local objPos = startObj:getPosition()
      pos = { x = objPos.x, y = objPos.y, z = objPos.z }
      if playerPos then
        distance = math.floor((objPos - playerPos):length())
      end
    elseif burnoutEvent.zoneName then
      local zone = getZoneByName(sites, burnoutEvent.zoneName)
      local zonePos = getZoneCentroid(zone)
      if zonePos then
        pos = {x = zonePos.x, y = zonePos.y, z = zonePos.z}
        if playerPos then
          distance = math.floor((zonePos - playerPos):length())
        end
      end
    end
    if pos then
      mNavTargets[burnoutEvent.eventId] = vec3(pos.x, pos.y, pos.z)
    end

    local currentVehicleBestEntry = {}
    if currentVehicleId then
      currentVehicleBestEntry = leaderboardManager.getLeaderboardEntry(currentVehicleId, burnoutEvent.label) or {}
    end

    events[burnoutEvent.eventId] = {
      raceName = burnoutEvent.eventId,
      label = burnoutEvent.label,
      types = burnoutEvent.types,
      bestTime = nil,
      reward = getBurnoutDisplayReward(burnoutEvent),
      baseReward = burnoutEvent.reward,
      hotlap = nil,
      hasDamageFactor = false,
      damageFactor = 0,
      hasTopSpeed = false,
      topSpeedGoal = nil,
      hasDrift = false,
      driftGoal = nil,
      hasBurnout = true,
      isOpenScore = true,
      scoreGoal = burnoutEvent.scoreGoal,
      hasAltRoute = false,
      altRouteLabel = nil,
      altRouteBestTime = nil,
      altRouteReward = nil,
      position = pos,
      distance = distance,
      thumbnail = burnoutEvent.thumbnail,
      currentVehicleBestTime = currentVehicleBestEntry.time,
      currentVehicleBestScore = currentVehicleBestEntry.driftScore,
      currentVehicleName = currentVehicleName,
      vehicleRecords = buildVehicleRecords(allVehicles, burnoutEvent.label),
    }
  end
end

local function getEventsData()
  log('D', logTag, "getEventsData: called")
  if not isCareerActive() then
    log('D', logTag, "getEventsData: career not active, returning empty")
    guihooks.trigger('phoneFreeroamEventsData', { events = {}, careerActive = false })
    return
  end

  local levelId = getCurrentLevel()
  if not levelId or levelId == '' then
    local missionFilename = getMissionFilename and getMissionFilename() or ''
    log('D', logTag, string.format("getEventsData: no levelId (mission=%s)", tostring(missionFilename)))
    guihooks.trigger('phoneFreeroamEventsData', { events = {}, careerActive = true, levelId = '' })
    return
  end
  log('D', logTag, string.format("getEventsData: levelId=%s", levelId))

  local races = loadRaceData()
  if not races or not next(races) then
    log('D', logTag, "getEventsData: no races found")
    races = {}
  end

  -- Get current vehicle
  local currentVehicleId = nil
  local currentVehicleName = "No Vehicle"
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 then
    currentVehicleId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
  end

  -- Get all vehicles for leaderboard lookups
  local allVehicles = {}
  if career_modules_inventory and career_modules_inventory.getVehicles then
    allVehicles = career_modules_inventory.getVehicles() or {}
  end

  if currentVehicleId and allVehicles[currentVehicleId] then
    currentVehicleName = getVehicleDisplayName(allVehicles[currentVehicleId])
  end

  -- Get player position for distance calc
  local playerPos = getPlayerPos()

  mNavTargets = {}
  local events = {}
  for raceName, race in pairs(races) do
    -- Get position from scene tree
    local pos = nil
    local distance = -1
    local startObj = scenetree.findObject("fre_start_" .. raceName)
    if startObj then
      local objPos = startObj:getPosition()
      pos = { x = objPos.x, y = objPos.y, z = objPos.z }
      mNavTargets[raceName] = vec3(objPos.x, objPos.y, objPos.z)
      if playerPos then
        distance = math.floor((objPos - playerPos):length())
      end
    end

    -- Build thumbnail path
    local thumbnail = "/levels/" .. levelId .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

    -- Get current vehicle best time
    local currentVehicleBestTime = nil
    local currentVehicleBestEntry = {}
    if currentVehicleId then
      currentVehicleBestEntry = leaderboardManager.getLeaderboardEntry(currentVehicleId, race.label) or {}
      currentVehicleBestTime = currentVehicleBestEntry.time
    end

    events[raceName] = {
      raceName = raceName,
      label = race.label or raceName,
      types = race.type or {},
      bestTime = race.bestTime,
      reward = race.reward,
      hotlap = race.hotlap,
      hasDamageFactor = (race.damageFactor ~= nil and race.damageFactor > 0),
      damageFactor = race.damageFactor or 0,
      hasTopSpeed = (race.topSpeed ~= nil and race.topSpeed ~= false),
      topSpeedGoal = race.topSpeedGoal,
      hasDrift = (race.driftGoal ~= nil),
      driftGoal = race.driftGoal,
      hasAltRoute = (race.altRoute ~= nil),
      altRouteLabel = race.altRoute and race.altRoute.label,
      altRouteBestTime = race.altRoute and race.altRoute.bestTime,
      altRouteReward = race.altRoute and race.altRoute.reward,
      position = pos,
      distance = distance,
      thumbnail = thumbnail,
      currentVehicleBestTime = currentVehicleBestTime,
      currentVehicleName = currentVehicleName,
      vehicleRecords = buildVehicleRecords(allVehicles, race.label),
    }
  end

  addBurnoutEvents(events, levelId, currentVehicleId, currentVehicleName, allVehicles, playerPos)
  appendDemoEvents(events, levelId, playerPos, allVehicles, currentVehicleId, currentVehicleName)

  if not next(events) then
    log('D', logTag, "getEventsData: no race_data or demo events found")
    guihooks.trigger('phoneFreeroamEventsData', { events = {}, careerActive = true, levelId = levelId })
    return
  end

  local eventCount = 0
  for _ in pairs(events) do eventCount = eventCount + 1 end
  log('D', logTag, string.format("getEventsData: sending %d events", eventCount))
  guihooks.trigger('phoneFreeroamEventsData', {
    events = events,
    careerActive = true,
    currentVehicleId = currentVehicleId,
    currentVehicleName = currentVehicleName,
    levelId = levelId,
  })
end

local function resolveBurnoutNavPos(burnoutEvent)
  if burnoutEvent.triggerName then
    local startObj = scenetree.findObject(burnoutEvent.triggerName)
    if startObj then
      return startObj:getPosition()
    end
  end
  if type(burnoutEvent.zoneName) == "string" and burnoutEvent.zoneName ~= "" then
    local data = burnoutConfig.loadLevelData(getCurrentLevel())
    return getZoneCentroid(data.zonesByName[burnoutEvent.zoneName])
  end
  return nil
end

local function navigateToEvent(raceName)
  local burnoutEvent = getBurnoutDefinitionByEventId(raceName)
  local pos = nil
  if burnoutEvent then
    pos = resolveBurnoutNavPos(burnoutEvent)
  else
    local startObj = scenetree.findObject("fre_start_" .. raceName)
    if startObj then
      pos = startObj:getPosition()
    elseif mNavTargets[raceName] then
      pos = mNavTargets[raceName]
    end
  end
  if pos and core_groundMarkers then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true })
  end
end

M.getEventsData = getEventsData
M.navigateToEvent = navigateToEvent

return M
