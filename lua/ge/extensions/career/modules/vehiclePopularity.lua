local M = {}

M.dependencies = {"career_career", "career_modules_inventory", "career_modules_valueCalculator", "career_saveSystem"}

local saveFile = "vehiclePopularityArchive.json"
local archive = {}

local SCENE_HISTORY_MAX = 40
local CAR_REP_MULT_PER_POINT = 0.02
local CAR_REP_MULT_MAX = 1.5

local function sceneToast(title, message, kind, ttl, meta)
  if guihooks and guihooks.trigger then
    guihooks.trigger("CarMeetToast", {
      title = title or "Car Scene",
      message = message or "",
      kind = kind or "info",
      ttl = ttl or 5,
      meta = meta,
      source = "Car Meets"
    })
  elseif type(ui_message) == "function" then
    ui_message(message or title or "Car Scene", ttl or 5, title or "Car Scene", kind or "info")
  end
end

local function getCurrentInventoryVehicle()
  if not career_modules_inventory or not career_modules_inventory.getCurrentVehicle then return nil, nil end
  local inventoryId = career_modules_inventory.getCurrentVehicle()
  if not inventoryId or not career_modules_inventory.getVehicles then return nil, nil end
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  return inventoryId, vehicle
end

local function getSavePath(currentSavePath)
  if not currentSavePath and career_saveSystem and career_saveSystem.getCurrentProfile then
    local _, savePath = career_saveSystem.getCurrentProfile()
    currentSavePath = savePath
  end
  if not currentSavePath then return nil end
  return currentSavePath .. "/career/rls_career/" .. saveFile
end

local function loadArchive()
  archive = {}
  if not career_career or not career_career.isActive or not career_career.isActive() then return end
  local filePath = getSavePath()
  if not filePath then return end
  local data = jsonReadFile(filePath)
  if type(data) == "table" and type(data.previousCars) == "table" then
    archive = data.previousCars
  end
end

local function ensureTracker(vehicle)
  vehicle.rlsLocalPopularity = vehicle.rlsLocalPopularity or {
    totalPercent = 0,
    meetsAttended = 0,
    events = {}
  }
  vehicle.rlsLocalPopularity.events = vehicle.rlsLocalPopularity.events or {}
  vehicle.rlsLocalPopularity.totalPercent = tonumber(vehicle.rlsLocalPopularity.totalPercent) or 0
  vehicle.rlsLocalPopularity.meetsAttended = tonumber(vehicle.rlsLocalPopularity.meetsAttended) or 0
  return vehicle.rlsLocalPopularity
end

local function roundPercent(value)
  return math.floor((tonumber(value) or 0) * 100 + 0.5) / 100
end

local function resolveDisplayName(raw, fallback)
  if raw == nil then
    return fallback
  end
  if core_locales and core_locales.translateWithOrWithoutContext then
    local translated = core_locales.translateWithOrWithoutContext(raw)
    if type(translated) == "string" and translated ~= "" then
      return translated
    end
  end
  if type(raw) == "string" and raw ~= "" then
    return raw
  end
  return fallback
end

local function getVehicleDisplayName(vehicle, inventoryId)
  local fallback = "Vehicle " .. tostring(inventoryId)
  if type(vehicle) ~= "table" then
    return fallback
  end
  return resolveDisplayName(vehicle.niceName or vehicle.Name or vehicle.model, fallback)
end

local function roundRep(value)
  return math.floor((tonumber(value) or 0) * 10 + 0.5) / 10
end

local function getVehicleMeetReputation(inventoryId, vehicle)
  if career_modules_inventory and career_modules_inventory.getMeetReputation then
    return tonumber(career_modules_inventory.getMeetReputation(inventoryId)) or 0
  end
  if type(vehicle) == "table" then
    return tonumber(vehicle.meetReputation) or 0
  end
  return 0
end

local function getPlayerRepMultiplier(inventoryId)
  local rep = getVehicleMeetReputation(inventoryId)
  return math.min(CAR_REP_MULT_MAX, 1 + (rep * CAR_REP_MULT_PER_POINT))
end

local function getSceneRepBonusPercent(inventoryId)
  return math.floor((getPlayerRepMultiplier(inventoryId) - 1) * 100 + 0.5)
end

local function ensureSceneHistory(vehicle)
  vehicle.rlsSceneHistory = vehicle.rlsSceneHistory or { events = {} }
  vehicle.rlsSceneHistory.events = vehicle.rlsSceneHistory.events or {}
  return vehicle.rlsSceneHistory
end

local function migrateLegacyBuzzEvents(vehicle)
  local tracker = vehicle.rlsLocalPopularity
  local history = ensureSceneHistory(vehicle)
  if type(tracker) ~= "table" or type(tracker.events) ~= "table" then return end
  for _, legacy in ipairs(tracker.events) do
    if type(legacy) == "table" and legacy.amountPercent and not legacy._migrated then
      table.insert(history.events, 1, {
        kind = "buzz",
        time = legacy.time or os.time(),
        label = "Local buzz",
        buzzDelta = legacy.amountPercent,
        carRepDelta = legacy.amountPercent,
        location = legacy.zoneId,
        _migrated = true
      })
      legacy._migrated = true
    end
  end
end

local function appendSceneEvent(inventoryId, entry)
  if not inventoryId or type(entry) ~= "table" then return end
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return end
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if not vehicle then return end
  migrateLegacyBuzzEvents(vehicle)
  local history = ensureSceneHistory(vehicle)
  table.insert(history.events, 1, {
    kind = entry.kind or "event",
    time = entry.time or os.time(),
    label = entry.label or entry.kind or "Scene event",
    playerRep = entry.playerRep,
    carRepDelta = entry.carRepDelta,
    buzzDelta = entry.buzzDelta,
    location = entry.location,
    meetType = entry.meetType,
    price = entry.price
  })
  while #history.events > SCENE_HISTORY_MAX do
    table.remove(history.events)
  end
  if career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end
end

local function addCarRep(inventoryId, amount, reason)
  amount = tonumber(amount) or 0
  if amount == 0 or not inventoryId then return 0 end
  if career_modules_inventory and career_modules_inventory.addMeetReputation then
    career_modules_inventory.addMeetReputation(inventoryId, amount)
  end
  if career_modules_inventory and career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent({inventoryId})
  end
  return roundRep(getVehicleMeetReputation(inventoryId))
end

local function awardForCurrentVehicle(zone)
  local inventoryId, vehicle = getCurrentInventoryVehicle()
  if not inventoryId or not vehicle then return nil end

  local minPercent = tonumber(zone and zone.localPopularityRewardMinPercent) or 0.4
  local maxPercent = tonumber(zone and zone.localPopularityRewardMaxPercent) or 1.0
  local capPercent = tonumber(zone and zone.localPopularityCapPercent) or 8
  if maxPercent < minPercent then maxPercent = minPercent end

  local tracker = ensureTracker(vehicle)
  local remaining = math.max(0, capPercent - tracker.totalPercent)
  if remaining <= 0 then
    return {
      inventoryId = inventoryId,
      amountPercent = 0,
      totalPercent = roundPercent(tracker.totalPercent),
      capped = true
    }
  end

  local rolled = minPercent + (math.random() * (maxPercent - minPercent))
  local amount = roundPercent(math.min(rolled, remaining))
  if amount <= 0 then return nil end

  tracker.totalPercent = roundPercent(tracker.totalPercent + amount)
  tracker.meetsAttended = tracker.meetsAttended + 1
  table.insert(tracker.events, {
    time = os.time(),
    zoneId = zone and zone.id or "unknown",
    zoneType = zone and zone.type or "meet",
    amountPercent = amount,
    totalPercent = tracker.totalPercent
  })

  while #tracker.events > 20 do
    table.remove(tracker.events, 1)
  end

  addCarRep(inventoryId, amount, "local buzz")
  appendSceneEvent(inventoryId, {
    kind = "buzz",
    label = "Local buzz",
    buzzDelta = amount,
    carRepDelta = amount,
    location = zone and zone.id or nil
  })
  if career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent({inventoryId})
  end

  return {
    inventoryId = inventoryId,
    amountPercent = amount,
    totalPercent = tracker.totalPercent,
    capped = tracker.totalPercent >= capPercent
  }
end

local function buildCarRepEntry(inventoryId, vehicle)
  if not inventoryId or type(vehicle) ~= "table" then return nil end
  return {
    inventoryId = inventoryId,
    name = getVehicleDisplayName(vehicle, inventoryId),
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    meetReputation = roundRep(getVehicleMeetReputation(inventoryId, vehicle)),
    sceneRepBonusPercent = getSceneRepBonusPercent(inventoryId),
    sceneRepMultiplier = roundRep(getPlayerRepMultiplier(inventoryId))
  }
end

local function getOwnedCarRepVehicles()
  local result = {}
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return result end
  for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
    local entry = buildCarRepEntry(inventoryId, vehicle)
    if entry then
      table.insert(result, entry)
    end
  end
  table.sort(result, function(a, b)
    if (a.meetReputation or 0) == (b.meetReputation or 0) then
      return tostring(a.name or "") < tostring(b.name or "")
    end
    return (a.meetReputation or 0) > (b.meetReputation or 0)
  end)
  return result
end

local function buildVehicleEntry(inventoryId, vehicle, soldPrice)
  if not inventoryId or type(vehicle) ~= "table" then return nil end
  local tracker = vehicle.rlsLocalPopularity
  if type(tracker) ~= "table" or ((tonumber(tracker.totalPercent) or 0) <= 0 and (tonumber(tracker.meetsAttended) or 0) <= 0) then
    return nil
  end

  local value
  if career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue and career_modules_inventory and career_modules_inventory.getVehicle then
    value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true)
  end

  return {
    inventoryId = inventoryId,
    name = getVehicleDisplayName(vehicle, inventoryId),
    year = vehicle.year,
    mileage = vehicle.mileage or vehicle.Mileage,
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    totalPercent = roundPercent(tracker.totalPercent),
    meetsAttended = tonumber(tracker.meetsAttended) or 0,
    estimatedValue = value and math.floor(value + 0.5) or nil,
    soldPrice = soldPrice and math.floor((tonumber(soldPrice) or 0) + 0.5) or nil,
    lastSeenAt = os.time(),
    events = deepcopy(tracker.events or {})
  }
end

local function formatFreValue(raceName, value)
  value = tonumber(value)
  if not value then return "-" end
  local name = tostring(raceName or ""):lower()
  if string.find(name, "drift", 1, true) then
    return string.format("%.0f pts", value)
  end
  local minutes = math.floor(value / 60)
  local seconds = value - (minutes * 60)
  return string.format("%d:%05.2f", minutes, seconds)
end

local function buildFreeroamTimesList(freTimes)
  local result = {}
  if type(freTimes) ~= "table" then return result end
  for raceName, value in pairs(freTimes) do
    table.insert(result, {
      raceName = raceName,
      value = value,
      displayValue = formatFreValue(raceName, value)
    })
  end
  table.sort(result, function(a, b)
    return tostring(a.raceName or "") < tostring(b.raceName or "")
  end)
  return result
end

local function getSceneEventsFromSource(vehicle, archivedEntry)
  if archivedEntry and type(archivedEntry.sceneEvents) == "table" then
    return deepcopy(archivedEntry.sceneEvents)
  end
  if type(vehicle) ~= "table" then return {} end
  migrateLegacyBuzzEvents(vehicle)
  local history = vehicle.rlsSceneHistory
  if type(history) == "table" and type(history.events) == "table" then
    return deepcopy(history.events)
  end
  return {}
end

local function buildArchiveEntry(inventoryId, vehicle, soldPrice)
  if not inventoryId or type(vehicle) ~= "table" then return nil end
  migrateLegacyBuzzEvents(vehicle)
  local tracker = vehicle.rlsLocalPopularity
  local totalPercent = type(tracker) == "table" and roundPercent(tracker.totalPercent) or 0
  local meetsAttended = type(tracker) == "table" and (tonumber(tracker.meetsAttended) or 0) or 0
  local meetReputation = roundRep(getVehicleMeetReputation(inventoryId, vehicle))
  local sceneEvents = getSceneEventsFromSource(vehicle)
  if meetReputation <= 0 and totalPercent <= 0 and meetsAttended <= 0 and #sceneEvents == 0
      and (type(vehicle.FRETimes) ~= "table" or not next(vehicle.FRETimes or {})) then
    return nil
  end

  return {
    inventoryId = inventoryId,
    name = getVehicleDisplayName(vehicle, inventoryId),
    year = vehicle.year,
    mileage = vehicle.mileage or vehicle.Mileage,
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    totalPercent = totalPercent,
    meetsAttended = meetsAttended,
    meetReputation = meetReputation,
    soldPrice = soldPrice and math.floor((tonumber(soldPrice) or 0) + 0.5) or nil,
    lastSeenAt = os.time(),
    sold = true,
    sceneEvents = sceneEvents,
    FRETimes = deepcopy(vehicle.FRETimes or {}),
    FRECompletions = deepcopy(vehicle.FRECompletions or {})
  }
end

local function archiveVehicle(inventoryId, soldPrice)
  if not inventoryId or not career_modules_inventory or not career_modules_inventory.getVehicles then return false end
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  local entry = buildArchiveEntry(inventoryId, vehicle, soldPrice)
  if not entry then return false end
  table.insert(archive, 1, entry)
  while #archive > 40 do
    table.remove(archive)
  end
  return true
end

local function buildHistoryListEntry(inventoryId, vehicle, archivedEntry, archiveIndex)
  if archivedEntry then
    return {
      inventoryId = archivedEntry.inventoryId or inventoryId,
      archiveIndex = archiveIndex,
      sold = true,
      name = resolveDisplayName(archivedEntry.name, "Vehicle " .. tostring(archivedEntry.inventoryId or inventoryId or "")),
      thumbnail = archivedEntry.thumbnail,
      meetReputation = roundRep(archivedEntry.meetReputation or 0),
      totalPercent = roundPercent(archivedEntry.totalPercent or 0),
      meetsAttended = tonumber(archivedEntry.meetsAttended) or 0,
      soldPrice = archivedEntry.soldPrice,
      lastSeenAt = archivedEntry.lastSeenAt
    }
  end
  if not inventoryId or type(vehicle) ~= "table" then return nil end
  local tracker = vehicle.rlsLocalPopularity
  return {
    inventoryId = inventoryId,
    archiveIndex = nil,
    sold = false,
    name = getVehicleDisplayName(vehicle, inventoryId),
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    meetReputation = roundRep(getVehicleMeetReputation(inventoryId, vehicle)),
    totalPercent = type(tracker) == "table" and roundPercent(tracker.totalPercent) or 0,
    meetsAttended = type(tracker) == "table" and (tonumber(tracker.meetsAttended) or 0) or 0,
    soldPrice = nil,
    lastSeenAt = nil
  }
end

local function getHistoryList()
  local result = {}
  if career_modules_inventory and career_modules_inventory.getVehicles then
    for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
      local entry = buildHistoryListEntry(inventoryId, vehicle)
      if entry then
        table.insert(result, entry)
      end
    end
  end
  for index, archivedEntry in ipairs(archive or {}) do
    local entry = buildHistoryListEntry(archivedEntry.inventoryId, nil, archivedEntry, index)
    if entry then
      table.insert(result, entry)
    end
  end
  table.sort(result, function(a, b)
    if (a.sold and not b.sold) then return false end
    if (not a.sold and b.sold) then return true end
    if (a.meetReputation or 0) == (b.meetReputation or 0) then
      return tostring(a.name or "") < tostring(b.name or "")
    end
    return (a.meetReputation or 0) > (b.meetReputation or 0)
  end)
  return result
end

local function getVehicleHistoryDetail(inventoryId, archiveIndex)
  local archivedEntry = nil
  if archiveIndex and archive[archiveIndex] then
    archivedEntry = archive[archiveIndex]
    inventoryId = archivedEntry.inventoryId or inventoryId
  end

  local vehicle = nil
  if not archivedEntry and career_modules_inventory and career_modules_inventory.getVehicles then
    vehicle = career_modules_inventory.getVehicles()[inventoryId]
  end
  if not vehicle and not archivedEntry then return nil end

  local name = archivedEntry and resolveDisplayName(archivedEntry.name, "Vehicle " .. tostring(inventoryId))
      or getVehicleDisplayName(vehicle, inventoryId)
  local meetReputation = archivedEntry and roundRep(archivedEntry.meetReputation or 0) or roundRep(getVehicleMeetReputation(inventoryId, vehicle))
  local tracker = vehicle and vehicle.rlsLocalPopularity
  local totalPercent = archivedEntry and roundPercent(archivedEntry.totalPercent or 0)
      or (type(tracker) == "table" and roundPercent(tracker.totalPercent) or 0)
  local meetsAttended = archivedEntry and (tonumber(archivedEntry.meetsAttended) or 0)
      or (type(tracker) == "table" and (tonumber(tracker.meetsAttended) or 0) or 0)

  local value
  if not archivedEntry and career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue then
    value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true)
  end

  local freTimes = archivedEntry and archivedEntry.FRETimes or (vehicle and vehicle.FRETimes)
  local sceneEvents = getSceneEventsFromSource(vehicle, archivedEntry)

  return {
    inventoryId = inventoryId,
    archiveIndex = archiveIndex,
    sold = archivedEntry ~= nil,
    name = name,
    thumbnail = archivedEntry and archivedEntry.thumbnail
        or (career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId)),
    meetReputation = meetReputation,
    sceneRepBonusPercent = archivedEntry and 0 or getSceneRepBonusPercent(inventoryId),
    sceneRepMultiplier = archivedEntry and 1 or roundRep(getPlayerRepMultiplier(inventoryId)),
    totalPercent = totalPercent,
    meetsAttended = meetsAttended,
    estimatedValue = value and math.floor(value + 0.5) or nil,
    soldPrice = archivedEntry and archivedEntry.soldPrice or nil,
    sceneEvents = sceneEvents,
    freeroamTimes = buildFreeroamTimesList(freTimes)
  }
end

local function requestVehicleHistory(inventoryId, archiveIndex)
  local detail = getVehicleHistoryDetail(inventoryId, archiveIndex)
  if guihooks and guihooks.trigger then
    guihooks.trigger("onVehicleSceneHistory", detail or {})
  end
  return detail
end

local function getOwnedPopularityVehicles()
  local result = {}
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return result end
  for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
    local entry = buildVehicleEntry(inventoryId, vehicle)
    if entry then
      table.insert(result, entry)
    end
  end
  table.sort(result, function(a, b)
    if (a.totalPercent or 0) == (b.totalPercent or 0) then
      return (a.meetsAttended or 0) > (b.meetsAttended or 0)
    end
    return (a.totalPercent or 0) > (b.totalPercent or 0)
  end)
  return result
end

local function getPhoneSocialData()
  return {
    careerActive = career_career and career_career.isActive and career_career.isActive() or false,
    vehicles = getOwnedPopularityVehicles(),
    carRepVehicles = getOwnedCarRepVehicles(),
    historyVehicles = getHistoryList(),
    previousCars = deepcopy(archive)
  }
end

local function requestPhoneSocialData()
  if guihooks and guihooks.trigger then
    guihooks.trigger("onCarMeetPopularityData", getPhoneSocialData())
  end
  return getPhoneSocialData()
end

local function getTracker(inventoryId)
  if not inventoryId then
    inventoryId = career_modules_inventory and career_modules_inventory.getCurrentVehicle and career_modules_inventory.getCurrentVehicle()
  end
  if not inventoryId or not career_modules_inventory or not career_modules_inventory.getVehicles then return nil end
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if not vehicle then return nil end
  return vehicle.rlsLocalPopularity
end

local function onBeforeVehicleSell(data)
  if type(data) == "table" then
    archiveVehicle(data.inventoryId, data.price)
  end
end

local function onSaveCurrentProfile(currentSavePath)
  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, {
    previousCars = archive
  }, true)
end

local function onCareerActive(active)
  if active then
    loadArchive()
  else
    archive = {}
  end
end

local function onExtensionLoaded()
  loadArchive()
end

M.awardForCurrentVehicle = awardForCurrentVehicle
M.getTracker = getTracker
M.getPhoneSocialData = getPhoneSocialData
M.requestPhoneSocialData = requestPhoneSocialData
M.getPlayerRepMultiplier = getPlayerRepMultiplier
M.getSceneRepBonusPercent = getSceneRepBonusPercent
M.appendSceneEvent = appendSceneEvent
M.addCarRep = addCarRep
M.getHistoryList = getHistoryList
M.getVehicleHistoryDetail = getVehicleHistoryDetail
M.requestVehicleHistory = requestVehicleHistory
M.archiveVehicle = archiveVehicle
M.onBeforeVehicleSell = onBeforeVehicleSell
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onCareerActive = onCareerActive
M.onExtensionLoaded = onExtensionLoaded
M.toast = sceneToast

return M
