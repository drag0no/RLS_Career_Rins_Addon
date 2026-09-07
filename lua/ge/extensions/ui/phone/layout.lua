local M = {}

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/phoneLayout.json"
local settingsRoot = "settings/RLS/"
local globalFile = settingsRoot .. "phoneLayout.json"
local backgroundsDir = "/Phone/Backgrounds/"
local layoutData = nil
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 2, 0.1
local LAYOUT_VERSION = 8

local PREINSTALLED_APP_IDS = {
  "settings",
  "app-store",
  "skills",
  "market-watch",
}

-- Channel key -> phone app id. Keep in sync with app manifest notifications[].
local NOTIFICATION_CHANNEL_APP_IDS = {
  ["carMeet.invite"] = "car-meet",
  ["racingTeam.raceReady"] = "racing-team",
  ["fre.contractReady"] = "fre-contracts",
  ["fre.cars"] = "fre-contracts",
  ["fre.difficulty"] = "fre-contracts",
  ["fre.discipline"] = "fre-contracts",
  ["tuningShop.jobCompleted"] = "tuning-shop",
  ["tuningShop.jobFailed"] = "tuning-shop",
  ["tuningShop.jobAvailable"] = "tuning-shop",
  ["loans.paymentMissed"] = "loans",
  ["loans.paymentMade"] = "loans",
  ["loans.paidOff"] = "loans",
  ["loans.approved"] = "loans",
  ["loans.prepayment"] = "loans",
  ["marketplace.newOffer"] = "marketplace",
  ["realEstate.mortgageMissed"] = "real-estate",
  ["realEstate.mortgageForeclosure"] = "real-estate",
  ["realEstate.mortgagePaidOff"] = "real-estate",
  ["realEstate.mortgageCreated"] = "real-estate",
  ["realEstate.mortgagePrepayment"] = "real-estate",
  ["realEstate.newOffer"] = "real-estate",
  ["rentals.rentDue"] = "rentals",
  ["rentals.eviction"] = "rentals",
  ["rentals.leaseSigned"] = "rentals",
  ["rentals.leaseComplete"] = "rentals",
  ["rentals.leaseTerminated"] = "rentals",
  ["beamEats.newOrder"] = "beam-eats",
  ["logistics.cargoAbandoned"] = "logistics",
  ["dakar.signedUp"] = "dakar",
  ["dakar.checkpoint"] = "dakar",
  ["roadAuthority.newReport"] = "road-authority",
  ["roadAuthority.reportsAvailable"] = "road-authority",
  ["weather.rainSoon"] = "weather",
  ["weather.stormSoon"] = "weather",
  ["weather.fogSoon"] = "weather",
}

-- Drop instead of queueing when the app is missing (player already got other feedback).
local NEVER_QUEUE_CHANNELS = {
  ["logistics.cargoAbandoned"] = true,
  ["weather.rainSoon"] = true,
  ["weather.stormSoon"] = true,
  ["weather.fogSoon"] = true,
}

-- On install: discard pending payloads and re-notify from live state.
local CLEAR_AND_SYNC_ON_INSTALL = {
  ["car-meet"] = true,
  ["racing-team"] = true,
  ["tuning-shop"] = true,
  ["fre-contracts"] = true,
  ["marketplace"] = true,
}

-- Keep one pending slot per entity (garage / listing), not one per channel.
local MULTI_INSTANCE_QUEUE_CHANNELS = {
  ["rentals.leaseComplete"] = true,
  ["rentals.leaseTerminated"] = true,
  ["rentals.eviction"] = true,
  ["realEstate.mortgagePaidOff"] = true,
  ["realEstate.mortgageForeclosure"] = true,
  ["realEstate.newOffer"] = true,
}

local function getBaseNotificationChannelKey(channelKey)
  if type(channelKey) ~= "string" or channelKey == "" then
    return channelKey
  end
  local base = channelKey:match("^([^:]+)")
  return base or channelKey
end

local function buildPendingQueueKey(channelKey, payload, opts)
  local base = getBaseNotificationChannelKey(channelKey)
  if not MULTI_INSTANCE_QUEUE_CHANNELS[base] then
    return base
  end
  local entityId = nil
  if type(opts) == "table" and opts.entityId ~= nil then
    entityId = tostring(opts.entityId)
  elseif type(payload) == "table" and payload.entityId ~= nil then
    entityId = tostring(payload.entityId)
  end
  if entityId and entityId ~= "" then
    return base .. ":" .. entityId
  end
  return base
end

local function clampScale(value)
  local n = tonumber(value)
  if not n then return 1 end
  local stepped = math.floor((n + SCALE_STEP * 0.5) / SCALE_STEP) * SCALE_STEP
  return math.max(SCALE_MIN, math.min(SCALE_MAX, stepped))
end

local function clampPosition(value)
  local n = tonumber(value)
  if not n then return 1 end
  return math.max(0, math.min(1, n))
end

local NOTIFICATION_DISPLAY_MIN, NOTIFICATION_DISPLAY_MAX, NOTIFICATION_DISPLAY_DEFAULT = 2, 15, 8

local function clampNotificationDisplaySeconds(value)
  local n = tonumber(value)
  if not n then return NOTIFICATION_DISPLAY_DEFAULT end
  return math.max(NOTIFICATION_DISPLAY_MIN, math.min(NOTIFICATION_DISPLAY_MAX, math.floor(n + 0.5)))
end

local imagePatterns = { "*.png", "*.jpg", "*.jpeg", "*.webp" }

local function getDefaultFreNotificationFilters()
  return {
    cars = {
      all = true,
      owned = {},
      other = true,
    },
    difficulty = {
      all = true,
      easy = true,
      medium = true,
      hard = true,
    },
    discipline = {
      all = true,
    },
  }
end

local function normalizeFreNotificationFilters(raw)
  local out = getDefaultFreNotificationFilters()
  if type(raw) ~= "table" then
    return out
  end

  if type(raw.cars) == "table" then
    if raw.cars.all ~= nil then out.cars.all = raw.cars.all ~= false end
    if raw.cars.other ~= nil then out.cars.other = raw.cars.other ~= false end
    if type(raw.cars.owned) == "table" then
      for k, v in pairs(raw.cars.owned) do
        local carModel = string.lower(tostring(k))
        out.cars.owned[carModel] = v ~= false
      end
    end
  end

  if type(raw.difficulty) == "table" then
    if raw.difficulty.all ~= nil then out.difficulty.all = raw.difficulty.all ~= false end
    if raw.difficulty.easy ~= nil then out.difficulty.easy = raw.difficulty.easy ~= false end
    if raw.difficulty.medium ~= nil then out.difficulty.medium = raw.difficulty.medium ~= false end
    if raw.difficulty.hard ~= nil then out.difficulty.hard = raw.difficulty.hard ~= false end
  end

  if type(raw.discipline) == "table" then
    if raw.discipline.all ~= nil then out.discipline.all = raw.discipline.all ~= false end
    for k, v in pairs(raw.discipline) do
      if type(k) == "string" and k ~= "all" then
        out.discipline[k] = v ~= false
      end
    end
  end

  return out
end

local function getDefaultSettings()
  return {
    phoneSize = 1,
    horizontalPosition = 1,
    backgroundColor = "#1509fb",
    backgroundImage = "",
    notifications = {},
    freNotificationFilters = getDefaultFreNotificationFilters(),
    doNotDisturb = false,
    doNotDisturbDurationMinutes = 0,
    doNotDisturbUntil = nil,
    lockScreenNotificationsEnabled = true,
    lockScreenContentMode = "show",
    lockScreenDisplaySeconds = NOTIFICATION_DISPLAY_DEFAULT,
    bannerNotificationsEnabled = true,
    bannerDisplaySeconds = NOTIFICATION_DISPLAY_DEFAULT,
  }
end

local DND_DURATION_VALUES = { [0] = true, [60] = true, [120] = true, [240] = true }

local function normalizeDndDurationMinutes(value)
  local n = tonumber(value)
  if not n or n < 0 or not DND_DURATION_VALUES[n] then return 0 end
  return n
end

local function normalizeDndUntil(value)
  if value == nil or value == "" then return nil end
  local n = tonumber(value)
  if not n or n <= 0 then return nil end
  return math.floor(n)
end

local function normalizeLockScreenContentMode(value)
  if value == "hide" then return "hide" end
  return "show"
end

local function getUnixNowSeconds()
  return os.time()
end

local function migrateLegacyNotificationSettings(settings)
  local out = {}
  if type(settings) == "table" then
    for k, v in pairs(settings) do
      out[k] = v
    end
  end
  if out.doNotDisturb == nil and settings.notificationsEnabled == false then
    out.doNotDisturb = true
  end
  if out.lockScreenContentMode == nil and settings.notificationsSimple == true then
    out.lockScreenContentMode = "hide"
  end
  local legacySeconds = settings.notificationDisplaySeconds
  if out.lockScreenDisplaySeconds == nil then
    out.lockScreenDisplaySeconds = legacySeconds or NOTIFICATION_DISPLAY_DEFAULT
  end
  if out.bannerDisplaySeconds == nil then
    out.bannerDisplaySeconds = legacySeconds or NOTIFICATION_DISPLAY_DEFAULT
  end
  if out.doNotDisturb == nil then
    out.doNotDisturb = false
  end
  if out.lockScreenNotificationsEnabled == nil then
    out.lockScreenNotificationsEnabled = true
  end
  if out.bannerNotificationsEnabled == nil then
    out.bannerNotificationsEnabled = true
  end
  if out.doNotDisturbDurationMinutes == nil then
    out.doNotDisturbDurationMinutes = 0
  end
  if out.lockScreenContentMode == nil then
    out.lockScreenContentMode = "show"
  end
  return out
end

-- Coerce a raw notifications map to string-keyed booleans, dropping junk.
local function normalizeNotifications(raw)
  local out = {}
  if type(raw) == "table" then
    for key, value in pairs(raw) do
      if type(key) == "string" then
        out[key] = value ~= false
      end
    end
  end
  return out
end

-- Validate the discovered-notification registry (channelKey -> {label, source}).
-- These channels are auto-recorded the first time a feature fires them, so a toggle
-- always exists in Settings even if the app manifest never declared the channel.
local function normalizeDiscoveredNotifications(raw)
  local out = {}
  if type(raw) == "table" then
    for key, meta in pairs(raw) do
      if type(key) == "string" and key ~= "" and type(meta) == "table" then
        out[key] = {
          label = type(meta.label) == "string" and meta.label or key,
          source = type(meta.source) == "string" and meta.source or "",
        }
      end
    end
  end
  return out
end

local function normalizeInstalledAppIds(raw)
  local out = {}
  local seen = {}
  if type(raw) == "table" then
    for _, id in ipairs(raw) do
      if type(id) == "string" and id ~= "" and not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  return out
end

-- channelKey -> { payload, opts?, queuedAt }. Latest entry wins per channel.
local function normalizePendingNotifications(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for channelKey, entry in pairs(raw) do
    if type(channelKey) == "string" and channelKey ~= "" and type(entry) == "table" then
      local storedOpts = nil
      if type(entry.opts) == "table" and type(entry.opts.appId) == "string" and entry.opts.appId ~= "" then
        storedOpts = { appId = entry.opts.appId }
      end
      out[channelKey] = {
        payload = type(entry.payload) == "table" and entry.payload or {},
        opts = storedOpts,
        queuedAt = tonumber(entry.queuedAt) or 0,
      }
    end
  end
  return out
end

local function collectInstalledFromLayout(layout)
  local seen = {}
  local out = {}
  local function addId(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    out[#out + 1] = id
  end
  for _, id in ipairs(PREINSTALLED_APP_IDS) do
    addId(id)
  end
  if type(layout) == "table" then
    for _, id in ipairs(normalizeInstalledAppIds(layout.installedAppIds)) do
      addId(id)
    end
    if type(layout.dock) == "table" then
      for _, id in ipairs(layout.dock) do
        addId(id)
      end
    end
    for _, page in ipairs(layout.pages or {}) do
      local apps = type(page) == "table" and page.apps or nil
      if type(apps) == "table" then
        for _, id in ipairs(apps) do
          addId(id)
        end
      end
    end
  end
  return out
end

local function normalizeSettings(rawSettings)
  local settings = migrateLegacyNotificationSettings(type(rawSettings) == "table" and rawSettings or {})
  local defaults = getDefaultSettings()

  local phoneSize = clampScale(settings.phoneSize)
  local horizontalPosition = clampPosition(settings.horizontalPosition)
  local backgroundColor = settings.backgroundColor
  if type(backgroundColor) ~= "string" or not string.match(backgroundColor, "^#%x%x%x%x%x%x$") then
    backgroundColor = defaults.backgroundColor
  else
    backgroundColor = string.lower(backgroundColor)
  end

  local backgroundImage = settings.backgroundImage
  if type(backgroundImage) ~= "string" then
    backgroundImage = defaults.backgroundImage
  end

  local doNotDisturb = settings.doNotDisturb == true
  local doNotDisturbUntil = normalizeDndUntil(settings.doNotDisturbUntil)
  if doNotDisturb and doNotDisturbUntil ~= nil and getUnixNowSeconds() >= doNotDisturbUntil then
    doNotDisturb = false
    doNotDisturbUntil = nil
  end

  return {
    phoneSize = phoneSize,
    horizontalPosition = horizontalPosition,
    backgroundColor = backgroundColor,
    backgroundImage = backgroundImage,
    notifications = normalizeNotifications(settings.notifications),
    freNotificationFilters = normalizeFreNotificationFilters(settings.freNotificationFilters),
    doNotDisturb = doNotDisturb,
    doNotDisturbDurationMinutes = normalizeDndDurationMinutes(settings.doNotDisturbDurationMinutes),
    doNotDisturbUntil = doNotDisturbUntil,
    lockScreenNotificationsEnabled = settings.lockScreenNotificationsEnabled ~= false,
    lockScreenContentMode = normalizeLockScreenContentMode(settings.lockScreenContentMode),
    lockScreenDisplaySeconds = clampNotificationDisplaySeconds(settings.lockScreenDisplaySeconds),
    bannerNotificationsEnabled = settings.bannerNotificationsEnabled ~= false,
    bannerDisplaySeconds = clampNotificationDisplaySeconds(settings.bannerDisplaySeconds),
  }
end

local function getPreinstalledAppIds()
  local out = {}
  for _, id in ipairs(PREINSTALLED_APP_IDS) do
    out[#out + 1] = id
  end
  return out
end

local function getDefaultInstalledAppIds()
  local out = getPreinstalledAppIds()
  out[#out + 1] = "guide"
  return out
end

local function getDefaultHomePageApps()
  local apps = {}
  for i = 1, 16 do
    apps[i] = (i == 1) and "guide" or ""
  end
  return apps
end

local function getDefaultLayout()
  return {
    version = LAYOUT_VERSION,
    wallpaper = "default",
    pages = {
      { apps = getDefaultHomePageApps() }
    },
    dock = getPreinstalledAppIds(),
    installedAppIds = getDefaultInstalledAppIds(),
    seenApps = {},
    removedAppIds = {},
    settings = getDefaultSettings(),
    discoveredNotifications = {},
    -- Latest notification per channel, held until the owning app is installed.
    pendingNotifications = {},
  }
end

-- Phone overhaul: empty home, new dock, reinstall catalog apps from the App Store.
local function applyPhoneOverhaulLayout(layout)
  layout.dock = getPreinstalledAppIds()
  layout.pages = {{ apps = {} }}
  layout.installedAppIds = getPreinstalledAppIds()
  layout.removedAppIds = {}
end

local function hasApp(layout, appId)
  if type(layout) ~= "table" or type(appId) ~= "string" or appId == "" then
    return false
  end

  for _, page in ipairs(layout.pages or {}) do
    for _, entry in ipairs((type(page) == "table" and page.apps) or {}) do
      if entry == appId then
        return true
      end
    end
  end

  for _, entry in ipairs(layout.dock or {}) do
    if entry == appId then
      return true
    end
  end

  return false
end

local function ensureFirstPageApps(layout)
  if type(layout.pages) ~= "table" then
    layout.pages = {}
  end
  if type(layout.pages[1]) ~= "table" then
    layout.pages[1] = {apps = {}}
  end
  if type(layout.pages[1].apps) ~= "table" then
    layout.pages[1].apps = {}
  end
  return layout.pages[1].apps
end

local function insertMissingApp(layout, appId, anchorAppId)
  if hasApp(layout, appId) then
    return false
  end

  local apps = ensureFirstPageApps(layout)
  local insertIndex = #apps + 1
  if type(anchorAppId) == "string" and anchorAppId ~= "" then
    for idx, entry in ipairs(apps) do
      if entry == anchorAppId then
        insertIndex = idx + 1
        break
      end
    end
  end

  table.insert(apps, insertIndex, appId)
  return true
end

local function removeApp(layout, appId)
  if type(layout) ~= "table" or type(appId) ~= "string" or appId == "" then
    return false
  end

  local changed = false
  for _, page in ipairs(layout.pages or {}) do
    local apps = type(page) == "table" and page.apps or nil
    if type(apps) == "table" then
      for i = #apps, 1, -1 do
        if apps[i] == appId then
          table.remove(apps, i)
          changed = true
        end
      end
    end
  end

  if type(layout.dock) == "table" then
    for i = #layout.dock, 1, -1 do
      if layout.dock[i] == appId then
        table.remove(layout.dock, i)
        changed = true
      end
    end
  end

  return changed
end

local function migrateLayoutData(data)
  local normalized = type(data) == "table" and data or getDefaultLayout()
  local changed = false
  local version = math.floor(tonumber(normalized.version) or 1)
  if version < LAYOUT_VERSION then
    changed = true
  end

  if version < 2 then
    insertMissingApp(normalized, "fre-contracts", "freeroam-events")
    changed = true
  end

  if version < 4 then
    if removeApp(normalized, "scene-invites") then
      changed = true
    end
  elseif removeApp(normalized, "scene-invites") then
    changed = true
  end

  if version < 7 then
    normalized.installedAppIds = collectInstalledFromLayout(normalized)
    changed = true
  end

  if version < 8 then
    applyPhoneOverhaulLayout(normalized)
    changed = true
  end

  normalized.version = LAYOUT_VERSION

  normalized.settings = normalizeSettings(normalized.settings)
  normalized.discoveredNotifications = normalizeDiscoveredNotifications(normalized.discoveredNotifications)
  normalized.pendingNotifications = normalizePendingNotifications(normalized.pendingNotifications)
  normalized.installedAppIds = normalizeInstalledAppIds(normalized.installedAppIds)
  if #normalized.installedAppIds == 0 then
    normalized.installedAppIds = collectInstalledFromLayout(normalized)
  end
  return normalized, changed
end

local function normalizeLayoutData(data)
  local normalized = migrateLayoutData(data)
  return normalized
end

-- Sanitize UI saves without re-running version migrations (avoids wiping layout on install).
local function sanitizeLayoutData(data)
  local normalized = type(data) == "table" and data or getDefaultLayout()
  local version = math.floor(tonumber(normalized.version) or LAYOUT_VERSION)
  if version > LAYOUT_VERSION then
    version = LAYOUT_VERSION
  end
  normalized.version = version
  normalized.settings = normalizeSettings(normalized.settings)
  normalized.discoveredNotifications = normalizeDiscoveredNotifications(normalized.discoveredNotifications)
  normalized.pendingNotifications = normalizePendingNotifications(normalized.pendingNotifications)
  normalized.installedAppIds = normalizeInstalledAppIds(normalized.installedAppIds)
  if #normalized.installedAppIds == 0 then
    normalized.installedAppIds = collectInstalledFromLayout(normalized)
  end
  return normalized
end

local function ensureSaveDir(currentSavePath)
  local dir = currentSavePath .. saveDir
  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end
end

local function ensureSettingsDir()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot, true)
  end
end

local function ensureBackgroundsDir()
  if not FS:directoryExists(backgroundsDir) then
    FS:directoryCreate(backgroundsDir, true)
  end
end

local function getCurrentSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentProfile then
    return nil
  end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  return currentSavePath
end

-- Sanitize data from JS while preserving empty-string slot placeholders.
local function sanitizeFromJS(data)
  if type(data) ~= "table" then
    return data
  end
  local out = {}
  for k, v in pairs(data) do
    out[k] = sanitizeFromJS(v)
  end
  return out
end

local function writeLayoutFile(path, data)
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    return career_saveSystem.jsonWriteFileSafe(path, data, true)
  end
  if jsonWriteFileSafe then
    return jsonWriteFileSafe(path, data, true)
  end
  if jsonWriteFile then
    return jsonWriteFile(path, data, true)
  end
  return false
end

local function loadLayout()
  local currentSavePath = getCurrentSavePath()

  -- 1) Career-specific layout (highest priority)
  if currentSavePath then
    local careerData = jsonReadFile(currentSavePath .. saveFile)
    if careerData then
      local migrated
      layoutData, migrated = migrateLayoutData(careerData)
      if migrated then
        ensureSaveDir(currentSavePath)
        writeLayoutFile(currentSavePath .. saveFile, layoutData)
      end
      return layoutData
    end
  end

  -- 2) Global freeroam/default layout in settings
  local globalData = jsonReadFile(globalFile)
  if globalData then
    local migrated
    layoutData, migrated = migrateLayoutData(globalData)
    if migrated then
      ensureSettingsDir()
      writeLayoutFile(globalFile, layoutData)
    end
    return layoutData
  end

  -- 3) Hardcoded default layout
  layoutData = normalizeLayoutData(getDefaultLayout())
  return layoutData
end

local function normalizeUiPath(path)
  if type(path) ~= "string" then return nil end
  local normalized = string.gsub(path, "\\", "/")
  if string.sub(normalized, 1, 1) ~= "/" then
    normalized = "/" .. normalized
  end
  return normalized
end

local function getFileName(path)
  if type(path) ~= "string" then return "" end
  local normalized = string.gsub(path, "\\", "/")
  return string.match(normalized, "([^/]+)$") or normalized
end

local function addCandidate(candidates, seen, path)
  if type(path) ~= "string" or path == "" then return end
  local normalized = string.gsub(path, "\\", "/")
  if not seen[normalized] then
    seen[normalized] = true
    table.insert(candidates, normalized)
  end
end

local function joinPath(base, tail)
  if type(base) ~= "string" or base == "" then return nil end
  if type(tail) ~= "string" or tail == "" then return base end
  local left = string.gsub(base, "\\", "/")
  local right = string.gsub(tail, "\\", "/")
  if string.sub(left, -1) ~= "/" then left = left .. "/" end
  if string.sub(right, 1, 1) == "/" then right = string.sub(right, 2) end
  return left .. right
end

local function saveLayout(data)
  if not data then return end
  if type(data) == "table" and data.pendingNotifications == nil and type(layoutData) == "table" then
    data.pendingNotifications = layoutData.pendingNotifications
  end
  data = sanitizeLayoutData(sanitizeFromJS(data))
  local currentSavePath = getCurrentSavePath()
  local writePath = nil
  local ok = false

  if currentSavePath then
    -- Career mode: write per-save layout
    ensureSaveDir(currentSavePath)
    writePath = currentSavePath .. saveFile
    ok = writeLayoutFile(writePath, data)
  else
    -- Freeroam/no active save: write global layout
    ensureSettingsDir()
    writePath = globalFile
    ok = writeLayoutFile(writePath, data)
  end

  if not ok then
    log('E', 'ui_phone_layout', string.format("Failed to write phone layout to '%s'", tostring(writePath)))
    return false
  end

  layoutData = data
  return true
end

local function emitLoadedLayout()
  local loaded = loadLayout()
  guihooks.trigger('phoneLayoutData', loaded)
  return loaded
end

local function requestLayout()
  emitLoadedLayout()
end

local function getInstalledIdSet(data)
  local set = {}
  if type(data) ~= "table" then return set end
  for _, id in ipairs(normalizeInstalledAppIds(data.installedAppIds)) do
    set[id] = true
  end
  return set
end

local function getSettings()
  local data = loadLayout()
  if type(data) ~= "table" then
    return getDefaultSettings()
  end
  return normalizeSettings(data.settings)
end

local function resolveNotificationAppId(channelKey, opts)
  if type(opts) == "table" and type(opts.appId) == "string" and opts.appId ~= "" then
    return opts.appId
  end
  if type(channelKey) == "string" and channelKey ~= "" then
    local base = getBaseNotificationChannelKey(channelKey)
    return NOTIFICATION_CHANNEL_APP_IDS[base] or NOTIFICATION_CHANNEL_APP_IDS[channelKey]
  end
  return nil
end

-- True when the app is on the player's phone (installedAppIds). System dock apps always count.
local function isAppInstalled(appId)
  if type(appId) ~= "string" or appId == "" then
    return true
  end
  for _, id in ipairs(PREINSTALLED_APP_IDS) do
    if id == appId then
      return true
    end
  end
  local data = loadLayout()
  if type(data) ~= "table" then
    return false
  end
  for _, id in ipairs(normalizeInstalledAppIds(data.installedAppIds)) do
    if id == appId then
      return true
    end
  end
  return false
end

local function isNotificationAppInstalled(channelKey, opts)
  local appId = resolveNotificationAppId(channelKey, opts)
  if not appId then
    return true
  end
  return isAppInstalled(appId)
end

local function getInstalledAppIds()
  local data = loadLayout()
  if type(data) ~= "table" then
    return getPreinstalledAppIds()
  end
  local seen = {}
  local out = {}
  local function addId(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    out[#out + 1] = id
  end
  for _, id in ipairs(PREINSTALLED_APP_IDS) do
    addId(id)
  end
  for _, id in ipairs(normalizeInstalledAppIds(data.installedAppIds)) do
    addId(id)
  end
  return out
end

-- Do not disturb blocks all phone notifications (including forcePeek).
local function isDoNotDisturbActive()
  local settings = getSettings()
  if type(settings) ~= "table" or settings.doNotDisturb ~= true then
    return false
  end
  local untilTs = normalizeDndUntil(settings.doNotDisturbUntil)
  if untilTs == nil then
    return true
  end
  return getUnixNowSeconds() < untilTs
end

local function isNotificationsMasterEnabled()
  return not isDoNotDisturbActive()
end

-- Shared gate for any feature that fires a phone notification.
-- Fail-open: unknown / unset channels are treated as enabled.
local function isNotificationEnabled(category)
  if type(category) ~= "string" or category == "" then return true end
  local base = getBaseNotificationChannelKey(category)
  local settings = getSettings()
  if type(settings) == "table" and type(settings.notifications) == "table" then
    local value = settings.notifications[base]
    if value == nil then
      value = settings.notifications[category]
    end
    if value ~= nil then
      return value ~= false
    end
  end
  return true
end

local function isFreContractNotificationAllowed(offer)
  if type(offer) ~= "table" then return true end
  if not isNotificationEnabled("fre.contractReady") then
    return false
  end

  local settings = getSettings()
  if type(settings) ~= "table" then return true end

  local filters = settings.freNotificationFilters
  if type(filters) ~= "table" then return true end

  local vPool = gameplay_events_freContracts_vehiclePool
  if not vPool and extensions and extensions.load then
    pcall(extensions.load, "gameplay_events_freContracts_vehiclePool")
    vPool = gameplay_events_freContracts_vehiclePool
  end

  local diff = filters.difficulty
  if type(diff) == "table" then
    if diff.all == false or not isNotificationEnabled("fre.difficulty") then
      return false
    end
    local tier = string.lower(tostring(offer.tier or "easy"))
    if diff[tier] == false then
      return false
    end
  end

  local disc = filters.discipline
  if type(disc) == "table" then
    if disc.all == false or not isNotificationEnabled("fre.discipline") then
      return false
    end
    local discId = tostring(offer.disciplineId or "")
    if disc[discId] == false then
      return false
    end
  end

  -- 3. Cars check
  local cars = filters.cars
  if type(cars) == "table" then
    if cars.all == false or not isNotificationEnabled("fre.cars") then
      return false
    end

    local requiredModel = offer.requiredModel or offer.requiredModelFamily or offer.model
    -- Contract does not require a specific vehicle ("any car")
    if not requiredModel or requiredModel == "" then
      return true
    end

    local ownedFilters = type(cars.owned) == "table" and cars.owned or {}
    local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}

    local reqLower = string.lower(tostring(requiredModel))
    for _, veh in pairs(vehicles) do
      if veh.owned ~= false then
        local vm = type(veh.model) == "string" and string.lower(veh.model) or nil
        if vm then
          local isMatch = (vPool and vPool.modelFamilyMatches) and vPool.modelFamilyMatches(requiredModel, vm) or (vm == reqLower)
          if isMatch then
            return ownedFilters[vm] ~= false
          end
        end
      end
    end

    return cars.other ~= false
  end

  return true
end

-- Record a channel the first time it is ever fired, deriving a display label/group
-- from the payload. Write-once: an app manifest can later override the label/grouping,
-- but we never auto-update an already-known entry (avoids label thrash + disk churn).
local function registerDiscoveredChannel(channelKey, payload)
  if type(channelKey) ~= "string" or channelKey == "" then return end
  channelKey = getBaseNotificationChannelKey(channelKey)

  -- Fast path: already known in memory, skip the disk round-trip.
  if type(layoutData) == "table" and type(layoutData.discoveredNotifications) == "table"
     and layoutData.discoveredNotifications[channelKey] ~= nil then
    return
  end

  local data = loadLayout()
  if type(data) ~= "table" then return end
  if type(data.discoveredNotifications) ~= "table" then
    data.discoveredNotifications = {}
  end
  if data.discoveredNotifications[channelKey] ~= nil then
    return
  end

  local source, label = "", channelKey
  if type(payload) == "table" then
    if type(payload.source) == "string" then source = payload.source end
    if type(payload.title) == "string" and payload.title ~= "" then label = payload.title end
  end
  data.discoveredNotifications[channelKey] = { label = label, source = source }
  saveLayout(data)
end

-- Flat list of every auto-discovered channel, for the Settings UI to merge with the
-- manifest-declared channels.
local function getKnownNotificationChannels()
  local data = loadLayout()
  local out = {}
  if type(data) == "table" and type(data.discoveredNotifications) == "table" then
    for key, meta in pairs(data.discoveredNotifications) do
      out[#out + 1] = {
        key = key,
        label = (type(meta) == "table" and type(meta.label) == "string") and meta.label or key,
        source = (type(meta) == "table" and type(meta.source) == "string") and meta.source or "",
      }
    end
  end
  return out
end

local function queuePendingNotification(channelKey, payload, opts)
  if type(channelKey) ~= "string" or channelKey == "" then return false end
  local data = loadLayout()
  if type(data) ~= "table" then return false end
  if type(data.pendingNotifications) ~= "table" then
    data.pendingNotifications = {}
  end
  local storedOpts = nil
  if type(opts) == "table" and type(opts.appId) == "string" and opts.appId ~= "" then
    storedOpts = { appId = opts.appId }
  end
  data.pendingNotifications[channelKey] = {
    payload = type(payload) == "table" and payload or {},
    opts = storedOpts,
    queuedAt = os.time(),
  }
  return saveLayout(data)
end

local function clearPendingNotificationsForApp(appId)
  if type(appId) ~= "string" or appId == "" then return end
  local data = loadLayout()
  if type(data) ~= "table" or type(data.pendingNotifications) ~= "table" then return end
  local changed = false
  for channelKey, entry in pairs(data.pendingNotifications) do
    if resolveNotificationAppId(channelKey, type(entry) == "table" and entry.opts or nil) == appId then
      data.pendingNotifications[channelKey] = nil
      changed = true
    end
  end
  if changed then
    saveLayout(data)
  end
end

local fireNotification

local function flushPendingNotificationsForApp(appId)
  if type(appId) ~= "string" or appId == "" then return false end
  local data = loadLayout()
  if type(data) ~= "table" or type(data.pendingNotifications) ~= "table" then return false end

  local toFlush = {}
  for channelKey, entry in pairs(data.pendingNotifications) do
    if type(channelKey) == "string" and type(entry) == "table" then
      if resolveNotificationAppId(channelKey, entry.opts) == appId then
        toFlush[#toFlush + 1] = { channelKey = channelKey, entry = entry }
      end
    end
  end
  if #toFlush == 0 then return false end

  for _, item in ipairs(toFlush) do
    data.pendingNotifications[item.channelKey] = nil
  end
  saveLayout(data)

  for _, item in ipairs(toFlush) do
    local flushOpts = type(item.entry.opts) == "table" and item.entry.opts or {}
    flushOpts._fromPendingQueue = true
    local baseKey = getBaseNotificationChannelKey(item.channelKey)
    fireNotification(baseKey, item.entry.payload, flushOpts)
  end
  return true
end

local PHONE_APP_INSTALL_SYNC_HANDLERS = {
  ["fre-contracts"] = function()
    if extensions and extensions.load then
      pcall(extensions.load, "gameplay_events_freContracts_offers")
    end
    if gameplay_events_freContracts_offers and gameplay_events_freContracts_offers.notifyOnPhoneAppInstalled then
      pcall(gameplay_events_freContracts_offers.notifyOnPhoneAppInstalled)
    end
  end,
  ["car-meet"] = function()
    if extensions and extensions.load then
      pcall(extensions.load, "career_modules_carmeets")
    end
    if career_modules_carmeets and career_modules_carmeets.notifyOnPhoneAppInstalled then
      pcall(career_modules_carmeets.notifyOnPhoneAppInstalled)
    end
  end,
  ["racing-team"] = function()
    if extensions and extensions.load then
      pcall(extensions.load, "career_modules_business_racingTeam")
    end
    if career_modules_business_racingTeam and career_modules_business_racingTeam.notifyOnPhoneAppInstalled then
      pcall(career_modules_business_racingTeam.notifyOnPhoneAppInstalled)
    end
  end,
  ["tuning-shop"] = function()
    if extensions and extensions.load then
      pcall(extensions.load, "career_modules_business_tuningShop")
    end
    if career_modules_business_tuningShop and career_modules_business_tuningShop.notifyOnPhoneAppInstalled then
      pcall(career_modules_business_tuningShop.notifyOnPhoneAppInstalled)
    end
  end,
  ["marketplace"] = function()
    if extensions and extensions.load then
      pcall(extensions.load, "career_modules_marketplace")
    end
    if career_modules_marketplace and career_modules_marketplace.notifyOnPhoneAppInstalled then
      pcall(career_modules_marketplace.notifyOnPhoneAppInstalled)
    end
  end,
}

local function syncNotificationsOnPhoneAppInstall(appId)
  local handler = PHONE_APP_INSTALL_SYNC_HANDLERS[appId]
  if handler then
    handler()
  end
end

-- Central dispatch for phone lock-screen notifications. Every feature should fire
-- through here so the channel gate can never be forgotten and the toggle always exists.
--   channelKey: namespaced channel (e.g. "carMeet.invite"); nil = ungated / always fire
--   payload:    table passed straight to the PhoneLockNotification guihook
--   opts.appId: optional app id override when the channel is not in NOTIFICATION_CHANNEL_APP_IDS
--   opts.fallback: optional function run when the phone surface is unavailable (no guihooks)
-- Returns true if a phone notification was dispatched.
fireNotification = function(channelKey, payload, opts)
  if isDoNotDisturbActive() then
    return false
  end
  local fromQueue = type(opts) == "table" and opts._fromPendingQueue == true
  local baseChannelKey = getBaseNotificationChannelKey(channelKey)
  if channelKey then
    if not fromQueue and not isNotificationAppInstalled(baseChannelKey, opts) then
      registerDiscoveredChannel(baseChannelKey, payload)
      if NEVER_QUEUE_CHANNELS[baseChannelKey] then
        return false
      end
      local queueKey = buildPendingQueueKey(baseChannelKey, payload, opts)
      queuePendingNotification(queueKey, payload, opts)
      return false
    end
    registerDiscoveredChannel(baseChannelKey, payload)
    if not isNotificationEnabled(baseChannelKey) then
      return false
    end
  end
  if guihooks and guihooks.trigger then
    local triggerPayload = {}
    if type(payload) == "table" then
      for k, v in pairs(payload) do
        triggerPayload[k] = v
      end
    end
    if type(baseChannelKey) == "string" and baseChannelKey ~= "" then
      triggerPayload.channelKey = baseChannelKey
    end
    if type(opts) == "table" and type(opts.appId) == "string" and opts.appId ~= "" then
      triggerPayload.appId = opts.appId
    end
    guihooks.trigger("PhoneLockNotification", triggerPayload)
    return true
  end
  if type(opts) == "table" and type(opts.fallback) == "function" then
    pcall(opts.fallback)
  end
  return false
end

local function handleAppInstallSideEffects(beforeData, afterData)
  local before = getInstalledIdSet(beforeData)
  local after = getInstalledIdSet(afterData)

  for appId in pairs(before) do
    if not after[appId] then
      clearPendingNotificationsForApp(appId)
    end
  end

  for appId in pairs(after) do
    if not before[appId] then
      if CLEAR_AND_SYNC_ON_INSTALL[appId] then
        clearPendingNotificationsForApp(appId)
        syncNotificationsOnPhoneAppInstall(appId)
      else
        flushPendingNotificationsForApp(appId)
      end
    end
  end
end

local function updateLayout(data)
  local before = loadLayout()
  if not saveLayout(data) then
    return false
  end
  local loaded = emitLoadedLayout()
  handleAppInstallSideEffects(before, loaded)
  return true
end

local function updateSettings(settings)
  local data = loadLayout() or getDefaultLayout()
  local merged = normalizeSettings(data.settings)
  if type(settings) == "table" then
    for key, value in pairs(settings) do
      merged[key] = value
    end
  end
  data.settings = normalizeSettings(merged)
  if not saveLayout(data) then
    return false
  end
  emitLoadedLayout()
  return true
end

local function listBackgroundImages()
  ensureBackgroundsDir()
  local found = {}
  local seen = {}

  for _, pattern in ipairs(imagePatterns) do
    local files = FS:findFiles(backgroundsDir, pattern, 0, false, false) or {}
    for _, filePath in ipairs(files) do
      local resolvedPath = filePath
      if type(filePath) == "string" and not string.find(filePath, "/", 1, true) and not string.find(filePath, "\\", 1, true) then
        resolvedPath = backgroundsDir .. filePath
      end
      local uiPath = normalizeUiPath(resolvedPath)
      if uiPath and not seen[uiPath] then
        seen[uiPath] = true
        table.insert(found, {
          name = getFileName(filePath),
          path = uiPath,
        })
      end
    end
  end

  table.sort(found, function(a, b)
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)

  return found
end

local function getBackgroundFolder(_)
  ensureBackgroundsDir()
  if Engine and Engine.Platform and Engine.Platform.getFSInfo then
    local okInfo, fsInfo = pcall(Engine.Platform.getFSInfo)
    if okInfo and type(fsInfo) == "table" then
      for _, key in ipairs({ "userPath", "userpath", "workingDir", "workingDirectory", "cwd", "homePath" }) do
        if type(fsInfo[key]) == "string" and fsInfo[key] ~= "" then
          return joinPath(fsInfo[key], "Phone/Backgrounds/")
        end
      end
    end
  end
  return backgroundsDir
end

local function openBackgroundFolder(_)
  ensureBackgroundsDir()

  if not (Engine and Engine.Platform and Engine.Platform.exploreFolder) then
    return false
  end

  local candidates = {}
  local seen = {}
  addCandidate(candidates, seen, backgroundsDir)

  -- Try filesystem helpers when available to get a real OS path.
  if FS then
    if type(FS.getFileRealPath) == "function" then
      addCandidate(candidates, seen, FS:getFileRealPath(backgroundsDir))
    end
    if type(FS.getAbsolutePath) == "function" then
      addCandidate(candidates, seen, FS:getAbsolutePath(backgroundsDir))
    end
  end

  if Engine.Platform.getFSInfo then
    local okInfo, fsInfo = pcall(Engine.Platform.getFSInfo)
    if okInfo and type(fsInfo) == "table" then
      for _, key in ipairs({ "userPath", "userpath", "workingDir", "workingDirectory", "cwd", "homePath" }) do
        if type(fsInfo[key]) == "string" and fsInfo[key] ~= "" then
          addCandidate(candidates, seen, joinPath(fsInfo[key], "Phone/Backgrounds/"))
        end
      end
    end
  end

  for _, path in ipairs(candidates) do
    local ok = pcall(function()
      Engine.Platform.exploreFolder(string.lower(path))
    end)
    if ok then return true end
  end

  return false
end

M.onSaveCurrentProfile = function(currentSavePath)
  if layoutData then
    ensureSaveDir(currentSavePath)
    local ok = writeLayoutFile(currentSavePath .. saveFile, layoutData)
    if not ok then
      log('E', 'ui_phone_layout', string.format("Failed to write phone layout on save-slot commit to '%s'", tostring(currentSavePath .. saveFile)))
    end
  end
end

M.onCareerModulesActivated = function()
  loadLayout()
end

M.requestLayout = requestLayout
M.updateLayout = updateLayout
M.getSettings = getSettings
M.updateSettings = updateSettings
M.isNotificationEnabled = isNotificationEnabled
M.isFreContractNotificationAllowed = isFreContractNotificationAllowed
M.isDoNotDisturbActive = isDoNotDisturbActive
M.isNotificationsMasterEnabled = isNotificationsMasterEnabled
M.isAppInstalled = isAppInstalled
M.getInstalledAppIds = getInstalledAppIds
M.fireNotification = fireNotification
M.getKnownNotificationChannels = getKnownNotificationChannels
M.listBackgroundImages = listBackgroundImages
M.getBackgroundFolder = getBackgroundFolder
M.openBackgroundFolder = openBackgroundFolder
M.getCareerActive = isCareerActive

local function getCurrentLevelId()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  return ""
end

M.getCurrentLevelId = getCurrentLevelId

return M
