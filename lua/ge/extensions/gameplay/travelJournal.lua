-- Career Travel Journal: profile-persistent scenic discovery and Photo Mode albums.
local M = {}

M.dependencies = {"gameplay_sites_sitesManager"}

local logTag = "travelJournal"
local APP_ID = "travel-journal"
local SCHEMA_VERSION = 1
local XP_ATTRIBUTE = "careerSkills-photography"
local LOCATION_XP = 1000
local MAP_COMPLETION_XP = 5000
local UPDATE_INTERVAL = 0.1
local PROMPT_ARM_DELAY_UPDATES = 1
local TRAVEL_MARKER_ICON = "poi_camera_round"
local PHOTO_ROOT_NAME = "TravelJournal"
local STATE_FILE_NAME = "journal.json"

local mapDefinitions = {}
local mapDefinitionList = {}
local currentSites = nil
local currentMapId = nil
local profileRoot = nil
local journalState = nil
local activeSession = nil
local pendingCandidate = nil
local zoneInside = {}
local updateAccumulator = 0
local interactArmed = false
local promptArmDelayUpdates = 0
local scenePromptVisible = false
local lastAppInstalledState = nil
local sessionSequence = 0
local mimeModule = nil
local photomodePatch = nil
local fallbackTrafficAmount = nil

local function now()
  return os.time()
end

local function normalizePath(value)
  return tostring(value or ""):gsub("\\", "/")
end

local function basename(value)
  return normalizePath(value):match("([^/]+)$") or "photo.png"
end

local function tableContains(values, needle)
  if type(values) ~= "table" then return false end
  for _, value in ipairs(values) do
    if value == needle then return true end
  end
  return false
end

local function removeValue(values, needle)
  if type(values) ~= "table" then return end
  for index = #values, 1, -1 do
    if values[index] == needle then table.remove(values, index) end
  end
end

local function getMime()
  if mimeModule ~= nil then return mimeModule end
  local ok, module = pcall(require, "mime")
  mimeModule = ok and module or false
  return mimeModule or nil
end

local function getCurrentProfileRoot()
  if not career_saveSystem or type(career_saveSystem.getCurrentProfile) ~= "function" then return nil end
  local _, savePath = career_saveSystem.getCurrentProfile()
  savePath = normalizePath(savePath)
  if savePath == "" then return nil end
  return savePath:match("^(.+)/[^/]+$") or savePath
end

local function getStateFilePath()
  return profileRoot and (profileRoot .. "/" .. PHOTO_ROOT_NAME .. "/" .. STATE_FILE_NAME) or nil
end

local function getPhotosRoot()
  return profileRoot and (profileRoot .. "/" .. PHOTO_ROOT_NAME .. "/Photos") or nil
end

local function ensureDirectory(dir)
  if not dir or dir == "" then return false end
  if FS:directoryExists(dir) then return true end
  FS:directoryCreate(dir, true)
  return FS:directoryExists(dir)
end

local function freshState()
  return {
    schemaVersion = SCHEMA_VERSION,
    maps = {},
    pendingSession = nil,
    pendingReview = nil,
  }
end

-- Persist only plain recovery data. Runtime environment snapshots may contain
-- engine objects that cannot be encoded safely as JSON.
local function persistentSession(session)
  if type(session) ~= "table" then return nil end
  return {
    id = session.id,
    mapId = session.mapId,
    locationId = session.locationId,
    startedAt = session.startedAt,
    importedSources = deepcopy(session.importedSources or {}),
    photoIds = deepcopy(session.photoIds or {}),
    photoSequence = tonumber(session.photoSequence) or 0,
  }
end

local function normalizeState(data)
  if type(data) ~= "table" then data = freshState() end
  data.schemaVersion = SCHEMA_VERSION
  data.maps = type(data.maps) == "table" and data.maps or {}
  for _, mapState in pairs(data.maps) do
    mapState.locations = type(mapState.locations) == "table" and mapState.locations or {}
    mapState.stampAwarded = mapState.stampAwarded == true
    for _, locationState in pairs(mapState.locations) do
      locationState.photos = type(locationState.photos) == "table" and locationState.photos or {}
      locationState.featuredPhotoIds = type(locationState.featuredPhotoIds) == "table" and locationState.featuredPhotoIds or {}
      locationState.rewardGranted = locationState.rewardGranted == true
    end
  end
  return data
end

local function saveState()
  local path = getStateFilePath()
  if not path or not journalState then return false end
  ensureDirectory(profileRoot .. "/" .. PHOTO_ROOT_NAME)
  -- This state changes outside the career autosave transaction. Using the
  -- career writer here would call saveFailed() on an I/O error and corrupt an
  -- otherwise healthy autosave slot, so keep this atomic write local.
  local tempPath = path .. ".tmp"
  if jsonWriteFile(tempPath, journalState, true) and FS:renameFile(tempPath, path) == 0 then
    return true
  end
  log("E", logTag, "Could not atomically save Travel Journal state to " .. tostring(path))
  if FS:fileExists(tempPath) then FS:removeFile(tempPath) end
  return false
end

local function getMapState(mapId, create)
  if not journalState then return nil end
  local state = journalState.maps[mapId]
  if not state and create then
    state = {locations = {}, stampAwarded = false}
    journalState.maps[mapId] = state
  end
  return state
end

local function getLocationState(mapId, locationId, create)
  local mapState = getMapState(mapId, create)
  if not mapState then return nil end
  local state = mapState.locations[locationId]
  if not state and create then
    state = {photos = {}, featuredPhotoIds = {}, rewardGranted = false}
    mapState.locations[locationId] = state
  end
  return state
end

local function findLocationDefinition(mapId, locationId)
  local mapDefinition = mapDefinitions[mapId]
  if not mapDefinition then return nil end
  for _, location in ipairs(mapDefinition.locations or {}) do
    if location.id == locationId then return location, mapDefinition end
  end
  return nil, mapDefinition
end

local function findPhoto(locationState, photoId)
  if not locationState then return nil, nil end
  for index, photo in ipairs(locationState.photos or {}) do
    if photo.id == photoId then return photo, index end
  end
  return nil, nil
end

local function emitStateChanged()
  if guihooks and guihooks.trigger then
    guihooks.trigger("TravelJournalStateChanged", M.getJournalState())
  end
end

local function emitScenePrompt(visible, candidate)
  scenePromptVisible = visible == true
  if not guihooks or not guihooks.trigger then return end
  if not scenePromptVisible or not candidate then
    guihooks.trigger("TravelJournalScenePrompt", {visible = false})
    return
  end
  guihooks.trigger("TravelJournalScenePrompt", {
    visible = true,
    mapId = candidate.mapId,
    locationId = candidate.locationId,
    locationName = candidate.location and candidate.location.name or "Scenic location",
    firstDiscovery = candidate.firstDiscovery == true,
    action = "gameplay_interact",
  })
end

local function toast(title, message, kind, ttl, action, dedupeKey)
  if guihooks and guihooks.trigger then
    guihooks.trigger("CarMeetToast", {
      title = title or "Travel Journal",
      message = message or "",
      kind = kind or "journal",
      ttl = ttl or 5,
      source = "Travel Journal",
      action = action,
      actionLabel = action and "Enter Scene" or nil,
      dedupeKey = dedupeKey,
    })
  elseif ui_message then
    ui_message(message or title, ttl or 5, title or "Travel Journal", kind or "info")
  end
end

local function loadDefinitions()
  mapDefinitions = {}
  mapDefinitionList = {}
  local paths = FS:findFiles("/levels/", "travelJournal.json", -1, true, false) or {}
  table.sort(paths)
  for _, filePath in ipairs(paths) do
    local definition = jsonReadFile(filePath)
    if type(definition) == "table" and type(definition.id) == "string" and type(definition.locations) == "table" then
      definition.sourcePath = filePath
      definition.order = tonumber(definition.order) or 999
      mapDefinitions[definition.id] = definition
      table.insert(mapDefinitionList, definition)
    else
      log("E", logTag, "Invalid Travel Journal map manifest: " .. tostring(filePath))
    end
  end
  table.sort(mapDefinitionList, function(a, b)
    if a.order == b.order then return tostring(a.name) < tostring(b.name) end
    return a.order < b.order
  end)
end

local function loadCurrentSites(force)
  currentMapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  currentSites = nil
  if not currentMapId or not mapDefinitions[currentMapId] then return end
  local sitePath = "/levels/" .. currentMapId .. "/travelJournal.sites.json"
  if FS:fileExists(sitePath) then
    currentSites = gameplay_sites_sitesManager.loadSites(sitePath, force == true, false)
  else
    log("E", logTag, "Missing Travel Journal sites file: " .. sitePath)
  end
end

local function validateContent()
  local result = {valid = true, errors = {}, maps = {}}
  for _, mapDefinition in ipairs(mapDefinitionList) do
    local mapResult = {id = mapDefinition.id, locationCount = #(mapDefinition.locations or {}), errors = {}}
    local ids = {}
    local expectedLocationCount = tonumber(mapDefinition.expectedLocationCount)
    if mapResult.locationCount < 1 then
      table.insert(mapResult.errors, "Expected at least one location")
    elseif expectedLocationCount and mapResult.locationCount ~= expectedLocationCount then
      table.insert(mapResult.errors, string.format("Expected exactly %d locations", expectedLocationCount))
    end
    local sites
    local sitePath = "/levels/" .. mapDefinition.id .. "/travelJournal.sites.json"
    if FS:fileExists(sitePath) then
      sites = gameplay_sites_sitesManager.loadSites(sitePath, true, true)
    else
      table.insert(mapResult.errors, "Missing " .. sitePath)
    end
    for _, location in ipairs(mapDefinition.locations or {}) do
      if type(location.id) ~= "string" or location.id == "" then
        table.insert(mapResult.errors, "Location has no stable id")
      elseif ids[location.id] then
        table.insert(mapResult.errors, "Duplicate location id: " .. location.id)
      else
        ids[location.id] = true
      end
      if type(location.name) ~= "string" or location.name == "" then
        table.insert(mapResult.errors, "Missing name for " .. tostring(location.id))
      end
      if location.scene and location.scene.fogAtmosphereHeight ~= nil
        and tonumber(location.scene.fogAtmosphereHeight) == nil then
        table.insert(mapResult.errors, "Invalid fogAtmosphereHeight for " .. tostring(location.id))
      end
      if sites then
        if not (sites.zones and sites.zones.byName and sites.zones.byName[location.zoneName]) then
          table.insert(mapResult.errors, "Missing zone '" .. tostring(location.zoneName) .. "'")
        end
        if not (sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName[location.parkingSpotName]) then
          table.insert(mapResult.errors, "Missing parking spot '" .. tostring(location.parkingSpotName) .. "'")
        end
      end
    end
    if #mapResult.errors > 0 then
      result.valid = false
      for _, message in ipairs(mapResult.errors) do
        table.insert(result.errors, mapDefinition.id .. ": " .. message)
      end
    end
    table.insert(result.maps, mapResult)
  end
  return result
end

local function isAppInstalled()
  if not ui_phone_layout and extensions and extensions.load then pcall(extensions.load, "ui_phone_layout") end
  return ui_phone_layout and type(ui_phone_layout.isAppInstalled) == "function" and ui_phone_layout.isAppInstalled(APP_ID) == true
end

local function callBoolean(module, method)
  if type(module) ~= "table" or type(module[method]) ~= "function" then return false end
  local ok, value = pcall(module[method])
  return ok and value == true
end

local function getRouteName()
  if not extensions or not extensions.ui_router or type(extensions.ui_router.getCurrent) ~= "function" then return nil end
  local route = extensions.ui_router.getCurrent()
  if not route then return nil end
  return (route.resolved and route.resolved.name) or (route.request and route.request.name) or (route.toRoute and route.toRoute.name)
end

local function isActivityBlocked(ignoreJournalUi)
  if not career_career or not career_career.isActive or not career_career.isActive() then return true end
  if activeSession then return true end
  if not ignoreJournalUi and gameplay_phone and gameplay_phone.isPhoneOpen and gameplay_phone.isPhoneOpen() then return true end
  local routeName = getRouteName()
  if routeName and routeName ~= "play" then
    local isJournalUiRoute = type(routeName) == "string"
      and (routeName:sub(1, 6) == "phone-" or routeName == "travel-journal")
    if not (ignoreJournalUi and isJournalUiRoute) then return true end
  end
  if gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId
    and gameplay_missions_missionManager.getForegroundMissionId() ~= nil then return true end
  if callBoolean(gameplay_walkabout, "isActive") or callBoolean(gameplay_walk, "isWalking") then return true end
  local freSession = gameplay_events_freeroam_session
  if freSession and (freSession.timerActive or freSession.mActiveRace or freSession.staged or freSession.dragPracticeActive or freSession.freeroamPracticeStaging) then return true end
  if gameplay_events_freeroam_utils and gameplay_events_freeroam_utils.isPlayerInPursuit
    and gameplay_events_freeroam_utils.isPlayerInPursuit() then return true end
  if career_modules_delivery_general and career_modules_delivery_general.isDeliveryModeActive
    and career_modules_delivery_general.isDeliveryModeActive() then return true end
  if callBoolean(gameplay_rlsTaxi, "isTaxiJobActive") then return true end
  if callBoolean(gameplay_beamEats, "isBeamEatsJobActive") then return true end
  if callBoolean(gameplay_facilityWork, "isFacilityWorkActive") then return true end
  if callBoolean(gameplay_ambulance, "isAmbulanceJobActive") then return true end
  if callBoolean(gameplay_bus, "isBusRouteActive") then return true end
  if gameplay_repo and gameplay_repo.getRepoJobInstance then
    local ok, instance = pcall(gameplay_repo.getRepoJobInstance)
    if ok and instance and (instance.isMonitoring or instance.vehicleId or instance.jobCoroutine) then return true end
  end
  return false
end

local function hasAttachedTrailer(vehicleId)
  if not vehicleId or not core_trailerRespawn then return false end
  if core_trailerRespawn.getTrailerData then
    local ok, data = pcall(core_trailerRespawn.getTrailerData)
    if ok and type(data) == "table" and data[vehicleId] then return true end
  end
  if core_trailerRespawn.getAttachedNonTrailer then
    local ok, towId = pcall(core_trailerRespawn.getAttachedNonTrailer, vehicleId)
    if ok and towId and towId ~= vehicleId then return true end
  end
  return false
end

local function expectedPhotographyXp()
  local total = 0
  for _, mapState in pairs((journalState and journalState.maps) or {}) do
    for _, locationState in pairs(mapState.locations or {}) do
      if locationState.rewardGranted then total = total + LOCATION_XP end
    end
    if mapState.stampAwarded then total = total + MAP_COMPLETION_XP end
  end
  return total
end

local function reconcilePhotographyXp()
  if not career_modules_playerAttributes or not career_modules_playerAttributes.getAttributeValue
    or not career_modules_playerAttributes.setAttributes then return false end
  local expected = expectedPhotographyXp()
  local current = tonumber(career_modules_playerAttributes.getAttributeValue(XP_ATTRIBUTE)) or 0
  if current >= expected then return true end
  career_modules_playerAttributes.setAttributes({[XP_ATTRIBUTE] = expected}, {
    label = "Travel Journal photography progress",
    tags = {"travelJournal", "photography"},
  })
  return true
end

local function updateRewards(mapId, locationId)
  local locationState = getLocationState(mapId, locationId, true)
  if not locationState.rewardGranted then
    locationState.rewardGranted = true
    locationState.completedAt = locationState.completedAt or now()
  end
  local mapState = getMapState(mapId, true)
  local mapDefinition = mapDefinitions[mapId]
  local completeCount = 0
  for _, location in ipairs((mapDefinition and mapDefinition.locations) or {}) do
    local progress = getLocationState(mapId, location.id, false)
    if progress and progress.completedAt then completeCount = completeCount + 1 end
  end
  local earnedStamp = completeCount == #((mapDefinition and mapDefinition.locations) or {}) and completeCount > 0
  if earnedStamp and not mapState.stampAwarded then
    mapState.stampAwarded = true
    mapState.stampEarnedAt = now()
    toast("Map complete", (mapDefinition.name or mapId) .. " stamp earned — 5,000 Photography XP", "success", 7)
  end
  saveState()
  reconcilePhotographyXp()
end

local function markDiscovered(mapId, locationId)
  local state = getLocationState(mapId, locationId, true)
  if state.discoveredAt then return false end
  state.discoveredAt = now()
  saveState()
  emitStateChanged()
  return true
end

local function resolvePhotoPath(photo)
  if not profileRoot or type(photo) ~= "table" or type(photo.relativePath) ~= "string" then return nil end
  return profileRoot .. "/" .. PHOTO_ROOT_NAME .. "/" .. photo.relativePath
end

local function copyScreenshotIntoJournal(sourcePath, session)
  sourcePath = normalizePath(sourcePath)
  if sourcePath == "" or not FS:fileExists(sourcePath) then return nil, "source_missing" end
  session.importedSources = session.importedSources or {}
  if session.importedSources[sourcePath] then return nil, "duplicate" end
  local locationState = getLocationState(session.mapId, session.locationId, true)
  for _, existing in ipairs(locationState.photos or {}) do
    if existing.sourceScreenshotPath == sourcePath then
      session.importedSources[sourcePath] = true
      return existing.id, "existing"
    end
  end

  local extension = sourcePath:lower():match("%.([a-z0-9]+)$") or "png"
  session.photoSequence = (session.photoSequence or 0) + 1
  local photoId = string.format("%s_%02d", session.id, session.photoSequence)
  local relativeDir = "Photos/" .. session.mapId .. "/" .. session.locationId
  local relativePath = relativeDir .. "/" .. photoId .. "." .. extension
  local absoluteDir = profileRoot .. "/" .. PHOTO_ROOT_NAME .. "/" .. relativeDir
  local destination = profileRoot .. "/" .. PHOTO_ROOT_NAME .. "/" .. relativePath
  if not ensureDirectory(absoluteDir) then return nil, "directory_failed" end
  if FS:copyFile(sourcePath, destination) ~= 0 then return nil, "copy_failed" end

  local photo = {
    id = photoId,
    relativePath = relativePath,
    sourceScreenshotPath = sourcePath,
    sourceFilename = basename(sourcePath),
    capturedAt = now(),
    sessionId = session.id,
  }
  table.insert(locationState.photos, photo)
  session.importedSources[sourcePath] = true
  session.photoIds = session.photoIds or {}
  table.insert(session.photoIds, photoId)
  if #(locationState.featuredPhotoIds or {}) < 3 then
    table.insert(locationState.featuredPhotoIds, photoId)
  end
  local firstCompletion = not locationState.completedAt
  if firstCompletion then
    locationState.completedAt = now()
    locationState.discoveredAt = locationState.discoveredAt or locationState.completedAt
  end
  journalState.pendingSession = persistentSession(session)
  saveState()
  if firstCompletion then
    updateRewards(session.mapId, session.locationId)
    toast("Location complete", "+1,000 Photography XP", "success", 6)
  else
    emitStateChanged()
  end
  return photoId
end

local function importCompletedScreenshotJobs()
  if not activeSession then return 0 end
  local ok, screenshotApi = pcall(require, "screenshot")
  if not ok or type(screenshotApi) ~= "table" or not screenshotApi.getScreenshotJobsSnapshotJson then return 0 end
  local encoded = screenshotApi.getScreenshotJobsSnapshotJson()
  local jobs = type(encoded) == "string" and jsonDecode(encoded) or encoded
  if type(jobs) ~= "table" then return 0 end
  local imported = 0
  for _, job in ipairs(jobs) do
    if job.phase == "done" and tonumber(job.result) == 0 and job.type == "full"
      and (job.bufferType == "color" or job.bufferType == "") and type(job.filename) == "string" then
      local stat = FS:stat(job.filename)
      local created = stat and (tonumber(stat.createtime) or tonumber(stat.modtime)) or 0
      if created >= (tonumber(activeSession.startedAt) or now()) - 2 then
        local photoId = copyScreenshotIntoJournal(job.filename, activeSession)
        if photoId then imported = imported + 1 end
      end
    end
  end
  if imported > 0 then emitStateChanged() end
  return imported
end

local function restoreEnvironmentAndTraffic()
  if activeSession and activeSession.environmentState and core_environment and core_environment.setState then
    pcall(core_environment.setState, activeSession.environmentState)
  end
  if career_modules_dynamicWeather and type(career_modules_dynamicWeather.setTravelJournalOverrideActive) == "function" then
    pcall(career_modules_dynamicWeather.setTravelJournalOverrideActive, false)
  end
  if gameplay_events_freeroam_utils and gameplay_events_freeroam_utils.restoreTrafficAmount then
    pcall(gameplay_events_freeroam_utils.restoreTrafficAmount)
  elseif gameplay_traffic and fallbackTrafficAmount ~= nil then
    pcall(gameplay_traffic.setActiveAmount, fallbackTrafficAmount)
  end
  fallbackTrafficAmount = nil
end

local function finalizePendingReviewWithFirstPhoto()
  local review = journalState and journalState.pendingReview
  if not review or type(review.photoIds) ~= "table" then return end
  local locationState = getLocationState(review.mapId, review.locationId, false)
  if locationState and review.photoIds[1] and findPhoto(locationState, review.photoIds[1]) then
    locationState.coverPhotoId = review.photoIds[1]
  end
  journalState.pendingReview = nil
  saveState()
end

local function finishScene(openReview)
  if not activeSession then return end
  importCompletedScreenshotJobs()
  restoreEnvironmentAndTraffic()
  local finished = activeSession
  activeSession = nil
  interactArmed = false
  promptArmDelayUpdates = 0
  journalState.pendingSession = nil
  if #(finished.photoIds or {}) > 0 then
    journalState.pendingReview = {
      sessionId = finished.id,
      mapId = finished.mapId,
      locationId = finished.locationId,
      photoIds = deepcopy(finished.photoIds),
    }
  end
  saveState()
  emitStateChanged()

  if #(finished.photoIds or {}) == 0 then
    toast("Scene ended", "No photograph was taken. The location remains incomplete.", "warning", 6)
    return
  end
  if openReview ~= false then
    core_jobsystem.create(function(job)
      job.sleep(0.2)
      if gameplay_phone and gameplay_phone.openRoute then
        gameplay_phone.openRoute("phone-travel-journal")
      elseif extensions and extensions.ui_router then
        extensions.ui_router.navigate("phone-travel-journal")
      end
    end)
  end
end

local function applyJournalCapabilities(payload)
  if not activeSession or type(payload) ~= "table" then return payload end
  payload.capabilities = type(payload.capabilities) == "table" and payload.capabilities or {}
  local capabilities = payload.capabilities
  capabilities.profile = "travelJournal"
  capabilities.sections = type(capabilities.sections) == "table" and capabilities.sections or {}
  capabilities.sections.camera = true
  capabilities.sections.scene = false
  capabilities.sections.effects = true
  capabilities.sections.capture = true
  capabilities.sections.developer = false
  capabilities.features = type(capabilities.features) == "table" and capabilities.features or {}
  capabilities.features.upload = false
  capabilities.features.steam = false
  capabilities.features.openShareUrl = false
  capabilities.features.resolutionPresets = false
  capabilities.features.motionBlurCapture = false
  capabilities.features.advancedRenderTuning = false
  capabilities.features.advancedRenderTuningUnlock = false
  capabilities.features.developerTools = false
  return payload
end

local applySceneEnvironment

local function resetPhotomodeCameraToVehicle(activateFreeCamera)
  -- Photo Mode preserves an already-active free camera and can also reapply a
  -- persistent camera pose. Re-anchor through the vehicle camera so the new
  -- free camera is created from the teleported vehicle's current transform.
  if activateFreeCamera and commands and type(commands.setFreeCamera) == "function" then
    local vehicle = be and be:getPlayerVehicle(0) or nil
    local oobb = vehicle and vehicle:getSpawnWorldOOBB() or nil
    if oobb then
      local center = vec3(oobb:getCenter())
      local halfExtents = vec3(oobb:getHalfExtents())
      local backward = vec3(oobb:getAxis(1))
      local up = vec3(oobb:getAxis(2))
      local cameraPos = center + backward * (halfExtents.y + 5) + up * (halfExtents.z + 2)
      local cameraRot = quatFromDir(center + up * 0.3 - cameraPos, up)
      local ok = pcall(function()
        commands.setFreeCamera()
        core_camera.setPosition(0, cameraPos)
        core_camera.setRotation(0, cameraRot)
        core_camera.resetCamera(0)
      end)
      if ok then return end
    end
  end
  if commands and type(commands.setGameCamera) == "function" then
    pcall(commands.setGameCamera)
  end
  if core_camera and type(core_camera.resetCamera) == "function" then
    pcall(core_camera.resetCamera, 0)
  end
end

local function patchPhotomode()
  if not ui_pause_photomode and extensions and extensions.load then pcall(extensions.load, "ui_pause_photomode") end
  if not ui_pause_photomode or ui_pause_photomode._travelJournalPatched then return false end
  photomodePatch = {
    begin = ui_pause_photomode.beginPhotomodeSession,
    finish = ui_pause_photomode.endPhotomodeSession,
    payload = ui_pause_photomode.getRoutePayload,
  }
  ui_pause_photomode.beginPhotomodeSession = function(options)
    if activeSession then options = {profile = "pause"} end
    local result = photomodePatch.begin(options)
    if activeSession and result ~= false then
      local location = findLocationDefinition(activeSession.mapId, activeSession.locationId)
      if location then applySceneEnvironment(location.scene or {}) end
      resetPhotomodeCameraToVehicle(true)
    end
    return result
  end
  ui_pause_photomode.endPhotomodeSession = function(...)
    local journalWasActive = activeSession ~= nil
    local result = photomodePatch.finish(...)
    if journalWasActive then finishScene(true) end
    return result
  end
  ui_pause_photomode.getRoutePayload = function(...)
    return applyJournalCapabilities(photomodePatch.payload(...))
  end
  ui_pause_photomode._travelJournalPatched = true
  return true
end

local function unpatchPhotomode()
  if not photomodePatch or not ui_pause_photomode then return end
  ui_pause_photomode.beginPhotomodeSession = photomodePatch.begin
  ui_pause_photomode.endPhotomodeSession = photomodePatch.finish
  ui_pause_photomode.getRoutePayload = photomodePatch.payload
  ui_pause_photomode._travelJournalPatched = nil
  photomodePatch = nil
end

applySceneEnvironment = function(preset)
  if not core_environment or type(preset) ~= "table" then return end
  if core_environment.setState then
    local state = deepcopy(preset)
    state.time = tonumber(state.timeOfDay)
    state.timeOfDay = nil
    if state.time ~= nil and state.play == nil then state.play = false end
    pcall(core_environment.setState, state)
    return
  end
  if preset.timeOfDay ~= nil and core_environment.setTimeOfDay then
    pcall(core_environment.setTimeOfDay, {time = tonumber(preset.timeOfDay) or 0, play = preset.play == true})
  end
  if preset.cloudCover ~= nil and core_environment.setCloudCover then
    pcall(core_environment.setCloudCover, tonumber(preset.cloudCover) or 0)
  end
  if preset.fogDensity ~= nil and core_environment.setFogDensity then
    -- Legacy fallback: presets use the freeroam Environment menu's scale.
    pcall(core_environment.setFogDensity, (tonumber(preset.fogDensity) or 0) / 1000)
  end
  if preset.fogAtmosphereHeight ~= nil and core_environment.setFogAtmosphereHeight then
    pcall(core_environment.setFogAtmosphereHeight, tonumber(preset.fogAtmosphereHeight) or 0)
  end
end

local function beginScene(mapId, locationId, ignoreJournalUi)
  if activeSession then return {success = false, reason = "scene_active"} end
  if not isAppInstalled() then return {success = false, reason = "app_not_installed"} end
  if isActivityBlocked(ignoreJournalUi) then return {success = false, reason = "activity_blocked"} end
  if mapId ~= currentMapId then return {success = false, reason = "wrong_map"} end
  local location = findLocationDefinition(mapId, locationId)
  if not location or not currentSites then return {success = false, reason = "content_missing"} end
  local zone = currentSites.zones and currentSites.zones.byName and currentSites.zones.byName[location.zoneName]
  local parking = currentSites.parkingSpots and currentSites.parkingSpots.byName and currentSites.parkingSpots.byName[location.parkingSpotName]
  local vehicle = be:getPlayerVehicle(0)
  if not zone or not parking then return {success = false, reason = "content_missing"} end
  if not vehicle or not zone:containsVehicle(vehicle, true) then return {success = false, reason = "outside_zone"} end
  if hasAttachedTrailer(vehicle:getID()) then return {success = false, reason = "trailer_attached"} end

  finalizePendingReviewWithFirstPhoto()
  sessionSequence = sessionSequence + 1
  local sessionId = string.format("%d_%03d", now(), sessionSequence)
  activeSession = {
    id = sessionId,
    mapId = mapId,
    locationId = locationId,
    startedAt = now(),
    importedSources = {},
    photoIds = {},
    photoSequence = 0,
    environmentState = core_environment and core_environment.getState and deepcopy(core_environment.getState()) or nil,
  }
  if career_modules_dynamicWeather and type(career_modules_dynamicWeather.setTravelJournalOverrideActive) == "function" then
    pcall(career_modules_dynamicWeather.setTravelJournalOverrideActive, true)
  end
  journalState.pendingSession = persistentSession(activeSession)
  saveState()

  emitScenePrompt(false)
  if guihooks and guihooks.trigger then guihooks.trigger("CarMeetToastClear") end

  if gameplay_events_freeroam_utils and gameplay_events_freeroam_utils.saveAndSetTrafficAmount then
    pcall(gameplay_events_freeroam_utils.saveAndSetTrafficAmount, 0)
  elseif gameplay_traffic then
    fallbackTrafficAmount = gameplay_traffic.getNumOfTraffic and gameplay_traffic.getNumOfTraffic() or nil
    pcall(gameplay_traffic.setActiveAmount, 0)
  end
  if ui_fadeScreen and ui_fadeScreen.start then ui_fadeScreen.start(0.35) end
  core_jobsystem.create(function(job)
    job.sleep(0.38)
    if not activeSession or activeSession.id ~= sessionId then return end
    spawn.safeTeleport(vehicle, parking.pos, parking.rot, nil, nil, nil, nil, false)
    job.sleep(0.18)
    resetPhotomodeCameraToVehicle(false)
    job.sleep(0.05)
    patchPhotomode()
    local result = extensions.ui_router.navigate("pause.photomode")
    if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(0.35) end
    if result and result.success == false then
      toast("Photo Mode unavailable", "The photography scene could not be opened.", "error", 6)
      finishScene(false)
    end
  end)
  return {success = true, sessionId = sessionId}
end

local function recoverPendingSession()
  local pending = journalState and journalState.pendingSession
  if type(pending) ~= "table" or type(pending.mapId) ~= "string" or type(pending.locationId) ~= "string" then return end
  pending.importedSources = type(pending.importedSources) == "table" and pending.importedSources or {}
  pending.photoIds = type(pending.photoIds) == "table" and pending.photoIds or {}
  activeSession = pending
  local candidates = {}
  for _, pattern in ipairs({"*.png", "*.jpg", "*.jpeg"}) do
    for _, filePath in ipairs(FS:findFiles("screenshots/", pattern, -1, true, false) or {}) do
      local stat = FS:stat(filePath)
      local created = stat and (tonumber(stat.createtime) or tonumber(stat.modtime)) or 0
      if created >= (tonumber(pending.startedAt) or now()) - 2 then table.insert(candidates, filePath) end
    end
  end
  table.sort(candidates)
  for _, filePath in ipairs(candidates) do copyScreenshotIntoJournal(filePath, pending) end
  activeSession = nil
  journalState.pendingSession = nil
  if #(pending.photoIds or {}) > 0 then
    journalState.pendingReview = {
      sessionId = pending.id,
      mapId = pending.mapId,
      locationId = pending.locationId,
      photoIds = deepcopy(pending.photoIds),
    }
    toast("Photos recovered", "A previous Travel Journal session was restored.", "success", 6)
  end
  saveState()
end

local function loadProfileState()
  profileRoot = getCurrentProfileRoot()
  if not profileRoot then
    journalState = freshState()
    return
  end
  ensureDirectory(profileRoot .. "/" .. PHOTO_ROOT_NAME)
  ensureDirectory(getPhotosRoot())
  journalState = normalizeState(jsonReadFile(getStateFilePath()))
  recoverPendingSession()
  reconcilePhotographyXp()
end

local function clearCandidate()
  emitScenePrompt(false)
  pendingCandidate = nil
  interactArmed = false
  promptArmDelayUpdates = 0
end

local function processZoneEntry(mapId, location, vehicle)
  if isActivityBlocked() then return end
  if not isAppInstalled() then
    toast("Scenic location nearby", "Install Travel Journal from the App Store to begin discovering locations.", "journal", 6, nil, "travelJournalInstall")
    return
  end
  markDiscovered(mapId, location.id)
end

local function updateZones()
  if activeSession or not currentSites or not currentMapId or not mapDefinitions[currentMapId] then return end
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then clearCandidate(); return end
  local pendingCandidateInside = false
  for _, location in ipairs(mapDefinitions[currentMapId].locations or {}) do
    local zone = currentSites.zones and currentSites.zones.byName and currentSites.zones.byName[location.zoneName]
    local inside = zone and zone:containsVehicle(vehicle, true) == true or false
    local wasInside = zoneInside[location.id] == true
    zoneInside[location.id] = inside
    if inside and not wasInside then
      processZoneEntry(currentMapId, location, vehicle)
    end
    if pendingCandidate and pendingCandidate.locationId == location.id and inside then
      pendingCandidateInside = true
    end
  end
  if pendingCandidate and (not pendingCandidateInside or not isAppInstalled() or isActivityBlocked()) then
    clearCandidate()
  end
end

local function promptFailure(reason)
  local messages = {
    scene_active = "A Travel Journal photography scene is already active.",
    app_not_installed = "Install Travel Journal from the App Store before opening this scene.",
    wrong_map = "This Travel Journal location is not on the current map.",
    activity_blocked = "Finish the current activity before entering the photography scene.",
    content_missing = "This Travel Journal location is missing its configured parking spot or scenic zone.",
    outside_zone = "Park inside the scenic area before opening the photography scene.",
    trailer_attached = "Detach the trailer before entering the photography scene.",
  }
  toast("Travel Journal unavailable", messages[reason] or "The photography scene is not available right now.", "warning", 6)
  return {success = false, reason = reason}
end

local function openMarkerPrompt(mapId, locationId)
  if activeSession then return promptFailure("scene_active") end
  if not isAppInstalled() then return promptFailure("app_not_installed") end
  if mapId ~= currentMapId then return promptFailure("wrong_map") end
  if isActivityBlocked() then return promptFailure("activity_blocked") end

  local location = findLocationDefinition(mapId, locationId)
  if not location or not currentSites then return promptFailure("content_missing") end
  local zone = currentSites.zones and currentSites.zones.byName and currentSites.zones.byName[location.zoneName]
  local parking = currentSites.parkingSpots and currentSites.parkingSpots.byName
    and currentSites.parkingSpots.byName[location.parkingSpotName]
  local vehicle = be:getPlayerVehicle(0)
  if not zone or not parking then return promptFailure("content_missing") end
  if not vehicle or not zone:containsVehicle(vehicle, true) then return promptFailure("outside_zone") end
  if hasAttachedTrailer(vehicle:getID()) then return promptFailure("trailer_attached") end

  local firstDiscovery = markDiscovered(mapId, location.id)
  pendingCandidate = {
    mapId = mapId,
    locationId = location.id,
    location = location,
    firstDiscovery = firstDiscovery,
  }
  interactArmed = false
  promptArmDelayUpdates = PROMPT_ARM_DELAY_UPDATES
  if gameplay_markerInteraction and gameplay_markerInteraction.closeViewDetailPrompt then
    gameplay_markerInteraction.closeViewDetailPrompt(true)
  end
  emitScenePrompt(true, pendingCandidate)
  return {success = true, mapId = mapId, locationId = locationId}
end

function M.onGameplayInteract()
  if not interactArmed or not scenePromptVisible or not pendingCandidate then return end
  local result = beginScene(pendingCandidate.mapId, pendingCandidate.locationId)
  if result and not result.success then promptFailure(result.reason) end
  return result
end

function M.enterPromptedScene(mapId, locationId)
  if not scenePromptVisible or not pendingCandidate then return {success = false, reason = "not_ready"} end
  if mapId ~= pendingCandidate.mapId or locationId ~= pendingCandidate.locationId then
    return {success = false, reason = "location_changed"}
  end
  return beginScene(mapId, locationId)
end

function M.dismissScenePrompt()
  clearCandidate()
  return true
end

function M.onCollectScreenshotMetadata(metadata)
  if not activeSession or type(metadata) ~= "table" then return end
  metadata.travelJournal = {
    schemaVersion = SCHEMA_VERSION,
    sessionId = activeSession.id,
    mapId = activeSession.mapId,
    locationId = activeSession.locationId,
  }
end

function M.onScreenshotAllDone()
  if activeSession then importCompletedScreenshotJobs() end
end

function M.getJournalState()
  journalState = journalState or freshState()
  local response = {
    schemaVersion = SCHEMA_VERSION,
    installed = isAppInstalled(),
    currentMapId = currentMapId,
    sceneActive = activeSession ~= nil,
    photographyXp = expectedPhotographyXp(),
    maps = {},
    pendingReview = journalState.pendingReview and deepcopy(journalState.pendingReview) or nil,
  }
  for _, definition in ipairs(mapDefinitionList) do
    local mapState = getMapState(definition.id, false) or {locations = {}}
    local mapUi = {
      id = definition.id,
      name = definition.name,
      order = definition.order,
      current = definition.id == currentMapId,
      stampAwarded = mapState.stampAwarded == true,
      stampEarnedAt = mapState.stampEarnedAt,
      stampLabel = definition.stampLabel or "Map Complete",
      locations = {},
      completedCount = 0,
      totalCount = #(definition.locations or {}),
    }
    for _, location in ipairs(definition.locations or {}) do
      local progress = getLocationState(definition.id, location.id, false) or {photos = {}, featuredPhotoIds = {}}
      local status = progress.completedAt and "completed" or (progress.discoveredAt and "discovered" or "notFound")
      if progress.completedAt then mapUi.completedCount = mapUi.completedCount + 1 end
      local photos = {}
      for _, photo in ipairs(progress.photos or {}) do
        table.insert(photos, {
          id = photo.id,
          capturedAt = photo.capturedAt,
          sourceFilename = photo.sourceFilename,
          featured = tableContains(progress.featuredPhotoIds, photo.id),
          cover = progress.coverPhotoId == photo.id,
        })
      end
      local insideZone = false
      if definition.id == currentMapId and currentSites then
        local zone = currentSites.zones and currentSites.zones.byName and currentSites.zones.byName[location.zoneName]
        local vehicle = be:getPlayerVehicle(0)
        insideZone = vehicle and zone and zone:containsVehicle(vehicle, true) == true or false
      end
      table.insert(mapUi.locations, {
        id = location.id,
        name = location.name,
        description = location.description,
        status = status,
        discoveredAt = progress.discoveredAt,
        completedAt = progress.completedAt,
        coverPhotoId = progress.coverPhotoId,
        featuredPhotoIds = deepcopy(progress.featuredPhotoIds or {}),
        photos = photos,
        photoCount = #photos,
        canNavigate = definition.id == currentMapId,
        insideZone = insideZone,
        canEnterScene = insideZone and isAppInstalled() and not activeSession and not isActivityBlocked(true),
      })
    end
    table.insert(response.maps, mapUi)
  end
  return response
end

function M.getPhotoDataUrl(mapId, locationId, photoId)
  local locationState = getLocationState(mapId, locationId, false)
  local photo = findPhoto(locationState, photoId)
  local filePath = resolvePhotoPath(photo)
  if not filePath or not FS:fileExists(filePath) then return nil end
  local expanded = FS:expandFilename(filePath)
  local file = expanded and io.open(expanded, "rb") or nil
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  local mime = getMime()
  if not data or not mime or not mime.b64 then return nil end
  local extension = filePath:lower():match("%.([a-z0-9]+)$")
  local mimeType = extension == "png" and "image/png" or "image/jpeg"
  return "data:" .. mimeType .. ";base64," .. mime.b64(data)
end

function M.setCoverPhoto(mapId, locationId, photoId)
  local locationState = getLocationState(mapId, locationId, false)
  if not locationState or not findPhoto(locationState, photoId) then return false end
  local previousCoverPhotoId = locationState.coverPhotoId
  locationState.coverPhotoId = photoId
  if not saveState() then
    locationState.coverPhotoId = previousCoverPhotoId
    return false
  end
  emitStateChanged()
  return true
end

function M.setFeaturedPhotos(mapId, locationId, photoIds)
  local locationState = getLocationState(mapId, locationId, false)
  if not locationState or type(photoIds) ~= "table" then return false end
  local sanitized, seen = {}, {}
  for _, photoId in ipairs(photoIds) do
    if #sanitized >= 3 then break end
    if type(photoId) == "string" and not seen[photoId] and findPhoto(locationState, photoId) then
      seen[photoId] = true
      table.insert(sanitized, photoId)
    end
  end
  local previousFeaturedPhotoIds = locationState.featuredPhotoIds
  locationState.featuredPhotoIds = sanitized
  if not saveState() then
    locationState.featuredPhotoIds = previousFeaturedPhotoIds
    return false
  end
  emitStateChanged()
  return true
end

function M.deletePhoto(mapId, locationId, photoId)
  local locationState = getLocationState(mapId, locationId, false)
  local photo, index = findPhoto(locationState, photoId)
  if not photo or not index then return false end
  local filePath = resolvePhotoPath(photo)
  local previousPhotos = deepcopy(locationState.photos)
  local previousFeaturedPhotoIds = deepcopy(locationState.featuredPhotoIds)
  local previousCoverPhotoId = locationState.coverPhotoId
  local previousReview = deepcopy(journalState.pendingReview)
  table.remove(locationState.photos, index)
  removeValue(locationState.featuredPhotoIds, photoId)
  if locationState.coverPhotoId == photoId then
    locationState.coverPhotoId = locationState.featuredPhotoIds[1]
      or (locationState.photos[#locationState.photos] and locationState.photos[#locationState.photos].id)
      or nil
  end
  if journalState.pendingReview and type(journalState.pendingReview.photoIds) == "table" then
    removeValue(journalState.pendingReview.photoIds, photoId)
    if #journalState.pendingReview.photoIds == 0 then journalState.pendingReview = nil end
  end
  if not saveState() then
    locationState.photos = previousPhotos
    locationState.featuredPhotoIds = previousFeaturedPhotoIds
    locationState.coverPhotoId = previousCoverPhotoId
    journalState.pendingReview = previousReview
    return false
  end
  -- Delete the journal-owned copy only after its metadata was committed. A
  -- failed file deletion leaves an unreferenced copy, not a broken journal.
  if filePath and FS:fileExists(filePath) then FS:removeFile(filePath) end
  emitStateChanged()
  return true
end

function M.completePendingReview(photoId)
  local review = journalState and journalState.pendingReview
  if not review then return false end
  local locationState = getLocationState(review.mapId, review.locationId, false)
  local chosen = photoId
  if not chosen or not tableContains(review.photoIds, chosen) or not findPhoto(locationState, chosen) then
    chosen = review.photoIds and review.photoIds[1]
  end
  local previousCoverPhotoId = locationState and locationState.coverPhotoId
  if chosen and locationState and findPhoto(locationState, chosen) then locationState.coverPhotoId = chosen end
  local previousReview = journalState.pendingReview
  journalState.pendingReview = nil
  if not saveState() then
    journalState.pendingReview = previousReview
    if locationState then locationState.coverPhotoId = previousCoverPhotoId end
    return false
  end
  emitStateChanged()
  return chosen ~= nil
end

function M.beginLocationScene(mapId, locationId)
  return beginScene(mapId, locationId)
end

function M.setRouteToLocation(mapId, locationId)
  if mapId ~= currentMapId then return {success = false, reason = "wrong_map"} end
  local location = findLocationDefinition(mapId, locationId)
  if not location or not currentSites then return {success = false, reason = "content_missing"} end
  local parking = currentSites.parkingSpots and currentSites.parkingSpots.byName
    and currentSites.parkingSpots.byName[location.parkingSpotName]
  if not parking or not parking.pos or not core_groundMarkers or not core_groundMarkers.setPath then
    return {success = false, reason = "navigation_unavailable"}
  end
  core_groundMarkers.setPath(parking.pos, {clearPathOnReachingTarget = true})
  toast("Route selected", location.name, "journal", 5, nil, "travelJournalRoute")
  return {success = true, mapId = mapId, locationId = locationId}
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not career_career or not career_career.isActive or not career_career.isActive() then return end
  if not isAppInstalled() or levelIdentifier ~= currentMapId or not currentSites then return end
  local definition = mapDefinitions[levelIdentifier]
  if not definition then return end

  for _, location in ipairs(definition.locations or {}) do
    local parking = currentSites.parkingSpots and currentSites.parkingSpots.byName
      and currentSites.parkingSpots.byName[location.parkingSpotName]
    if parking and parking.pos and parking.rot and parking.scl then
      local markerPath = type(parking.getPath) == "function" and parking:getPath()
        or ("travelJournal#" .. levelIdentifier .. "#" .. location.id)
      table.insert(elements, {
        id = "travelJournal-" .. levelIdentifier .. "-" .. location.id,
        data = {
          type = "travelJournalSpot",
          mapId = levelIdentifier,
          locationId = location.id,
          name = location.name,
        },
        markerInfo = {
          parkingMarker = {
            path = markerPath,
            pos = parking.pos,
            rot = parking.rot,
            scl = parking.scl,
            icon = TRAVEL_MARKER_ICON,
          },
          clusterType = "activity",
        },
      })
    end
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "travelJournalSpot" then
      local mapId = elem.mapId
      local locationId = elem.locationId
      table.insert(activityData, {
        icon = TRAVEL_MARKER_ICON,
        heading = elem.name or "Scenic Location",
        preheadings = {"Travel Journal"},
        startable = true,
        buttonLabel = "Open Travel Journal",
        buttonFun = function() openMarkerPrompt(mapId, locationId) end,
        sorting = {
          type = elem.type,
          id = locationId,
        },
      })
    end
  end
end

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData

local function requestSceneFromJournalUi(mapId, locationId, closePhone)
  if activeSession then return {success = false, reason = "scene_active"} end
  if not isAppInstalled() then return {success = false, reason = "app_not_installed"} end
  if mapId ~= currentMapId then return {success = false, reason = "wrong_map"} end
  if isActivityBlocked(true) then return {success = false, reason = "activity_blocked"} end
  local location = findLocationDefinition(mapId, locationId)
  if not location or not currentSites then return {success = false, reason = "content_missing"} end
  local zone = currentSites.zones and currentSites.zones.byName and currentSites.zones.byName[location.zoneName]
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle or not zone or not zone:containsVehicle(vehicle, true) then
    return {success = false, reason = "outside_zone"}
  end
  if hasAttachedTrailer(vehicle:getID()) then
    toast("Trailer attached", "Detach the trailer before entering the photography scene.", "warning", 6)
    return {success = false, reason = "trailer_attached"}
  end
  emitScenePrompt(false)
  if closePhone and gameplay_phone and gameplay_phone.closePhone then
    gameplay_phone.closePhone()
  elseif extensions and extensions.ui_router then
    extensions.ui_router.navigate("play")
  end
  core_jobsystem.create(function(job)
    job.sleep(0.25)
    local result = beginScene(mapId, locationId, true)
    if result and result.success == false then
      toast("Could not enter Photo Mode", "Return to the scenic area and try again.", "warning", 6)
    end
  end)
  return {success = true, queued = true}
end

function M.requestSceneFromPhone(mapId, locationId)
  return requestSceneFromJournalUi(mapId, locationId, true)
end

function M.requestSceneFromJournal(mapId, locationId)
  return requestSceneFromJournalUi(mapId, locationId, false)
end

function M.getContentValidation()
  return validateContent()
end

function M.getDebugState()
  return {
    currentMapId = currentMapId,
    profileRoot = profileRoot,
    appInstalled = isAppInstalled(),
    activityBlocked = isActivityBlocked(),
    activeSession = activeSession and deepcopy(activeSession) or nil,
    candidate = pendingCandidate and deepcopy(pendingCandidate) or nil,
    interactArmed = interactArmed,
    scenePromptVisible = scenePromptVisible,
    validation = validateContent(),
    expectedPhotographyXp = expectedPhotographyXp(),
  }
end

function M.debugTeleportToLocation(mapId, locationId)
  local location = findLocationDefinition(mapId, locationId)
  if mapId ~= currentMapId or not location or not currentSites then return false end
  local parking = currentSites.parkingSpots and currentSites.parkingSpots.byName and currentSites.parkingSpots.byName[location.parkingSpotName]
  local vehicle = be:getPlayerVehicle(0)
  if not parking or not vehicle then return false end
  spawn.safeTeleport(vehicle, parking.pos, parking.rot, nil, nil, nil, nil, false)
  zoneInside[locationId] = false
  return true
end

function M.onUpdate(dtReal)
  local appInstalled = isAppInstalled()
  if lastAppInstalledState ~= nil and lastAppInstalledState ~= appInstalled then
    if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
    if freeroam_bigMapPoiProvider and freeroam_bigMapPoiProvider.forceSend then
      freeroam_bigMapPoiProvider.forceSend()
    end
  end
  lastAppInstalledState = appInstalled

  if promptArmDelayUpdates > 0 then
    promptArmDelayUpdates = promptArmDelayUpdates - 1
    if promptArmDelayUpdates == 0 and pendingCandidate and scenePromptVisible then
      interactArmed = true
    end
  end

  updateAccumulator = updateAccumulator + (tonumber(dtReal) or 0)
  if updateAccumulator < UPDATE_INTERVAL then return end
  updateAccumulator = 0
  updateZones()
end

function M.onWorldReadyState(state)
  if state ~= 2 then return end
  loadDefinitions()
  loadCurrentSites(true)
  zoneInside = {}
  clearCandidate()
  lastAppInstalledState = isAppInstalled()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
  if career_career and career_career.isActive and career_career.isActive() then loadProfileState() end
end

function M.onClientEndMission()
  if activeSession then finishScene(false) end
  currentSites = nil
  currentMapId = nil
  zoneInside = {}
  clearCandidate()
  lastAppInstalledState = nil
end

function M.onCareerActivated()
  loadDefinitions()
  loadCurrentSites(true)
  loadProfileState()
  lastAppInstalledState = isAppInstalled()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
end

function M.onCareerActive(active)
  if active then
    M.onCareerActivated()
  else
    if activeSession then finishScene(false) end
    profileRoot = nil
    journalState = freshState()
    lastAppInstalledState = nil
  end
end

function M.onExtensionLoaded()
  loadDefinitions()
  loadCurrentSites(false)
  journalState = freshState()
  if career_career and career_career.isActive and career_career.isActive() then loadProfileState() end
  patchPhotomode()
  lastAppInstalledState = isAppInstalled()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
  local validation = validateContent()
  if not validation.valid then log("E", logTag, "Content validation failed: " .. dumps(validation.errors)) end
end

function M.onExtensionUnloaded()
  if activeSession then finishScene(false) end
  unpatchPhotomode()
end

return M
