local M = {}

local logTag = 'overrideManager'

local overrides = {}
local originalLoad = nil
local originalReload = nil

local MOD_OVERRIDES_DIR = "/overrides/"
local LOCAL_OVERRIDEN_ROOT = "/overriden/"
local mountedRoot = false

local ourMod = nil
local trafficVehicleOverrideClass = nil

-- These extensions are already alive by the time a mod's modScript runs in
-- 0.39. Reloading them through the extension manager tears through BeamNG's
-- dependency graph, while leaving them alone means the vanilla tables keep
-- handling the main-menu career/profile flow. Overlay the replacement module
-- onto the existing table instead: references and hook registration stay
-- valid, but every public implementation comes from Overhaul.
local EARLY_LOADED_OVERRIDES = {
  career_saveSystem = true,
  career_career = true,
  core_recoveryPrompt = true,
  freeroam_bigMapPoiProvider = true,
  freeroam_vueBigMap = true,
  gameplay_missions_progress = true,
  -- Traffic parking is already active before modScript runs and keeps its
  -- hook table. Patch it in place so reset/destroy races use our nil guards.
  gameplay_parking = true,
  gameplay_police = true,
  -- Already loaded with the level. Without a live overlay, stash still
  -- deactivates the career car and the 120s part-condition ping never returns.
  gameplay_missions_missionManager = true,
  -- ui_router require()'s this at boot and keeps a closed-over reference.
  -- Must patch the live table or pause Back (B/Circle) silently no-ops.
  ui_router_routeHandlers = true,
  -- These two are the only remaining overrides whose VANILLA file defines
  -- onSerialize/onDeserialized. On Ctrl+L, extensions.deserialize restores the
  -- extension batch in pairs() order and only then runs the deserialize hooks, so
  -- if one of these got loaded before installSystem() ran, its *vanilla* hook would
  -- fire -- and vanilla freeroam/facilities/fuelPrice.lua:38 indexes
  -- freeroam_facilities unguarded, which took the whole process down. Overlaying
  -- them in place means the hooks that run are ours (which do guard).
  freeroam_facilities_fuelPrice = true,
  gameplay_drift_freeroam_driftSpots = true,
  -- Loaded before modScript runs, so setOverride() only cleared its package.loaded
  -- entry and nothing re-pointed it: _G.freeroam_facilities kept the pre-override
  -- table while package.loaded['freeroam/facilities'] became the override -- two live
  -- copies with different behaviour. Overlay it in place so there is exactly one.
  freeroam_facilities = true,
}

local function isExtensionFormat(path)
  return path:find('_') and not path:find('/')
end

local function convertFormat(path)
  if isExtensionFormat(path) then
    return path:gsub('_', '/')
  else
    return path:gsub('/', '_')
  end
end

local function setOverride(originalPath, overridePath, overrideType)
  if not originalPath or not overridePath then
    return false
  end

  if not overrideType then
    overrideType = isExtensionFormat(originalPath) and 'extension' or 'require'
  end

  local convertedPath = convertFormat(originalPath)
  local isExtensionType = (overrideType == 'extension')

  local originalPreload = package.preload[convertedPath]
  local entry = {
    override = overridePath,
    originalFormat = originalPath,
    convertedFormat = convertedPath,
    isExtension = isExtensionType,
    originalPreload = originalPreload
  }

  overrides[originalPath] = entry
  overrides[convertedPath] = entry

  package.preload[convertedPath] = function(...)
    if originalPath:find('career_modules_') == 1 and (not career_career or not career_career.isActive()) then
      return nil
    end

    local success, result = xpcall(function()
      return require(overridePath)
    end, debug.traceback)

    if not success then
      log('E', logTag, 'Failed to load override "' .. tostring(overridePath) .. '" for "' .. tostring(originalPath) .. '":\n' .. tostring(result))
      error(result, 0)
    end

    return result
  end

  local absolutePath = '/lua/ge/extensions/' .. convertedPath
  package.preload[absolutePath] = package.preload[convertedPath]
  package.loaded[convertedPath] = nil
  package.loaded[absolutePath] = nil

  return true
end

local function findLiveModule(entry)
  if not entry then
    return nil
  end

  local liveExtension = rawget(_G, entry.originalFormat)
  if type(liveExtension) == "table" then
    return liveExtension
  end

  -- ui_router and similar modules use require(), which may only live in package.loaded.
  local requireKeys = {
    entry.convertedFormat,
    "/lua/ge/extensions/" .. entry.convertedFormat,
    "ge/extensions/" .. entry.convertedFormat,
  }
  for _, key in ipairs(requireKeys) do
    local loaded = package.loaded[key]
    if type(loaded) == "table" then
      return loaded
    end
  end

  return nil
end

-- BeamNG caches hook function pointers. Copying replacements onto a live
-- extension table leaves hooks such as onPreRender / onUpdate calling vanilla.
local function refreshLiveHooks(replacement)
  if not replacement or not extensions.hookUpdate then
    return
  end
  for key, value in pairs(replacement) do
    if type(value) == 'function' and key:sub(1, 2) == 'on' then
      extensions.hookUpdate(key)
    end
  end
end

local function overlayLoadedExtension(entry)
  if not entry or not EARLY_LOADED_OVERRIDES[entry.originalFormat] then
    return false
  end

  local liveExtension = findLiveModule(entry)
  if type(liveExtension) ~= "table" then
    log("W", logTag, "Early override skipped; live module not found: " .. tostring(entry.originalFormat))
    return false
  end

  package.loaded[entry.override] = nil
  local success, replacement = xpcall(function()
    return require(entry.override)
  end, debug.traceback)
  if not success then
    log('E', logTag, 'Failed to prepare live override "' .. tostring(entry.override) .. '" for "' .. tostring(entry.originalFormat) .. '":\n' .. tostring(replacement))
    error(replacement, 0)
  end
  if type(replacement) ~= "table" then
    local message = 'Live override "' .. tostring(entry.override) .. '" did not return a table'
    log('E', logTag, message)
    error(message, 0)
  end

  for key, value in pairs(replacement) do
    liveExtension[key] = value
  end
  refreshLiveHooks(replacement)

  -- Keep BeamNG's extension identity and any references held by other loaded
  -- extensions pointed at the table we just updated.
  package.loaded[entry.convertedFormat] = liveExtension
  package.loaded["/lua/ge/extensions/" .. entry.convertedFormat] = liveExtension
  package.loaded["ge/extensions/" .. entry.convertedFormat] = liveExtension

  -- The replacement module did not pass through extensions.load(), so perform
  -- the small amount of module-local initialization it normally receives.
  if type(replacement.onExtensionLoaded) == "function" then
    local initOk, initErr = xpcall(replacement.onExtensionLoaded, debug.traceback)
    if not initOk then
      log('E', logTag, 'Failed to initialize live override "' .. tostring(entry.originalFormat) .. '":\n' .. tostring(initErr))
      error(initErr, 0)
    end
  end

  log('I', logTag, 'Applied live override without reloading dependencies: ' .. entry.originalFormat)
  return true
end

local function clearDirectory(dirPath)
  if FS:directoryExists(dirPath) then
    FS:remove(dirPath)
    return true
  end
  return false
end

local function clearOverride(originalPath)
  local entry = overrides[originalPath]
  if not entry then
    return false
  end

  overrides[entry.originalFormat] = nil
  overrides[entry.convertedFormat] = nil

  if entry.originalPreload then
    package.preload[entry.convertedFormat] = entry.originalPreload
  else
    package.preload[entry.convertedFormat] = nil
  end

  local absolutePath = '/lua/ge/extensions/' .. entry.convertedFormat
  package.preload[absolutePath] = nil

  log('I', logTag, 'Cleared override for: ' .. originalPath)
  return true
end

local function copyFiles(srcDir, dstDir)
  local srcRoot = srcDir:gsub("\\", "/")
  if srcRoot:sub(-1) ~= "/" then
    srcRoot = srcRoot .. "/"
  end

  local dstRoot = dstDir:gsub("\\", "/")
  if dstRoot:sub(-1) ~= "/" then
    dstRoot = dstRoot .. "/"
  end

  if not FS:directoryExists(srcRoot) then
    return 0
  end

  if not FS:directoryExists(dstRoot) then
    FS:directoryCreate(dstRoot, true)
  end

  local copied = 0
  local uiFiles = FS:findFiles(srcRoot, "*", -1, true, false)
  dump(uiFiles)
  for _, file in ipairs(uiFiles) do
    local fileContent = readFile(file)
    if fileContent and writeFile(dstRoot .. file:sub(srcRoot:len() + 1), fileContent) then
      copied = copied + 1
    else
      print('failed to write file ' .. dstRoot .. file:sub(srcRoot:len() + 1))
    end
  end

  return copied
end

local function mountCustomOverrides()
  local copied = copyFiles(MOD_OVERRIDES_DIR, LOCAL_OVERRIDEN_ROOT)

  if not FS:directoryExists(LOCAL_OVERRIDEN_ROOT) then
    return false
  end

  if not FS:isMounted(LOCAL_OVERRIDEN_ROOT) then
    if FS:mount(LOCAL_OVERRIDEN_ROOT) then
      mountedRoot = true      

      if career_career and career_career.isActive() then
        guihooks.trigger('ChangeState', {
          state = 'play',
          params = {}
        })
      end
    else
      return false
    end
  else
    mountedRoot = true
  end
  return false
end

local function overrideLoad(...)
  local args = {...}
  local modifiedArgs = {}

  for _, arg in ipairs(args) do
    if type(arg) == 'string' then
      if arg:find('career_modules_') == 1 and (not career_career or not career_career.isActive()) then
      else
        -- Keep the original extension identity. setOverride() installs a
        -- package.preload entry for that name, which supplies the override.
        table.insert(modifiedArgs, arg)
      end
    else
      table.insert(modifiedArgs, arg)
    end
  end

  return originalLoad(unpack(modifiedArgs))
end

local function overrideReload(extPath)
  if type(extPath) ~= 'string' then
    return originalReload(extPath)
  end
  if extPath:find('career_modules_') == 1 and (not career_career or not career_career.isActive()) then
    return false
  end

  local entry = overrides[extPath]
  if entry then
    -- Keep the currently loaded package entry intact until BeamNG's own
    -- reload routine has resolved its source path and dependency graph. The
    -- reload routine clears that cache itself before requiring our preload.
    package.loaded[entry.override] = nil
    return originalReload(entry.originalFormat)
  else
    return originalReload(extPath)
  end
end

local function getTrafficVehicleOverrideEntry()
  return overrides.gameplay_traffic_vehicle or overrides['gameplay/traffic/vehicle']
end

local function getTrafficVehicleOverrideClass()
  if trafficVehicleOverrideClass then return trafficVehicleOverrideClass end

  local entry = getTrafficVehicleOverrideEntry()
  if not entry then
    log('E', logTag, 'Traffic vehicle override entry is missing')
    return nil
  end

  local ok, constructor = pcall(require, 'gameplay/traffic/vehicle')
  if not ok or type(constructor) ~= 'function' then
    log('E', logTag, 'Traffic vehicle override constructor could not be required: ' .. tostring(constructor))
    return nil
  end

  local overrideClass = package.loaded['overhaul/trafficVehicleOverrideClass']
  if type(overrideClass) == 'table' and type(overrideClass.checkCollisions) == 'function' then
    trafficVehicleOverrideClass = overrideClass
    return overrideClass
  end

  log('E', logTag, 'Traffic vehicle override class was not published by its constructor module')
  return nil
end

local function patchTrafficVehicleObject(id, veh)
  veh = veh or (gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()[id])
  if not veh then return false end
  if veh.rlsTrafficVehicleOverrideVersion == 1 then return true end

  local overrideClass = getTrafficVehicleOverrideClass()
  if not overrideClass then return false end
  setmetatable(veh, overrideClass)
  veh.rlsTrafficVehicleOverrideVersion = 1
  return true
end

local function patchLiveTrafficVehicles()
  if not gameplay_traffic or not gameplay_traffic.getTrafficData then return false end

  local checked, patched = 0, 0
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    checked = checked + 1
    if patchTrafficVehicleObject(id, veh) then patched = patched + 1 end
  end
  if checked > 0 then
    if patched == checked then
      log('I', logTag, string.format('Applied traffic vehicle override class to %d vehicles', patched))
    else
      log('E', logTag, string.format('Traffic vehicle override active on only %d of %d vehicles', patched, checked))
    end
  end
  return checked > 0 and patched == checked
end

local function installSystem()
  if originalLoad or originalReload then
    log('E', logTag, 'Override system already installed')
    return false
  end

  originalLoad = extensions.load
  if originalLoad then
    extensions.load = overrideLoad
  end

  originalReload = extensions.reload
  if originalReload then
    extensions.reload = overrideReload
  end

  local overridesDir = '/lua/ge/extensions/overrides/'
  local luaFiles = FS:findFiles(overridesDir, '*.lua', -1, true, false)

  -- Snapshot live early modules BEFORE setOverride clears package.loaded.
  local earlyLiveSnapshots = {}
  if luaFiles and #luaFiles > 0 then
    for _, overrideFile in ipairs(luaFiles) do
      local modulePath = overrideFile:gsub('^/lua/ge/extensions/', 'lua.ge.extensions.'):gsub('%.lua$', ''):gsub('/',
        '.')
      local originalPath = modulePath:gsub('%.overrides%.', '.')
      local extensionPath = originalPath:gsub('lua%.ge%.extensions%.', ''):gsub('%.', '_')
      if EARLY_LOADED_OVERRIDES[extensionPath] then
        local convertedPath = convertFormat(extensionPath)
        earlyLiveSnapshots[extensionPath] = findLiveModule({
          originalFormat = extensionPath,
          convertedFormat = convertedPath,
        })
      end
    end
  end

  local overrideCount = 0
  if luaFiles and #luaFiles > 0 then
    for _, overrideFile in ipairs(luaFiles) do
      local modulePath = overrideFile:gsub('^/lua/ge/extensions/', 'lua.ge.extensions.'):gsub('%.lua$', ''):gsub('/',
        '.')
      local originalPath = modulePath:gsub('%.overrides%.', '.')
      local extensionPath = originalPath:gsub('lua%.ge%.extensions%.', ''):gsub('%.', '_')

      if setOverride(extensionPath, modulePath) then
        overrideCount = overrideCount + 1
      end
    end
  end

  -- Apply the handful of boot-time replacements only after every preload has
  -- been registered, so their requires can resolve other overridden modules.
  for extensionName, _ in pairs(EARLY_LOADED_OVERRIDES) do
    local entry = overrides[extensionName]
    if entry and type(earlyLiveSnapshots[extensionName]) == "table" then
      -- Restore the pre-clear live table identity so closed-over require() refs update in place.
      local live = earlyLiveSnapshots[extensionName]
      rawset(_G, extensionName, live)
      package.loaded[entry.convertedFormat] = live
      package.loaded["/lua/ge/extensions/" .. entry.convertedFormat] = live
      package.loaded["ge/extensions/" .. entry.convertedFormat] = live
    end
    overlayLoadedExtension(entry)
  end

  -- gameplay_traffic caches the stock vehicle constructor before mods load.
  -- Swap existing objects to the override class in place; reloading the traffic
  -- extension here tears down mission and career dependencies during boot.
  getTrafficVehicleOverrideClass()
  patchLiveTrafficVehicles()

  -- Camera modes are require()'d and cached by core_camera; force rebuild so
  -- overrides/core/cameraModes/* take effect without a full game restart.
  if overrides['core_cameraModes_unicycle'] or overrides['core/cameraModes/unicycle'] then
    if core_camera and core_camera.onFileChanged then
      core_camera.onFileChanged('/lua/ge/extensions/core/cameraModes/unicycle.lua', 'added')
    end
  end

  clearDirectory(LOCAL_OVERRIDEN_ROOT)
  mountCustomOverrides()
  reloadUI()

  return true
end

local function unmountCustomOverrides()
  if FS:unmount(LOCAL_OVERRIDEN_ROOT) then
    mountedRoot = false
    return true
  end
  return false
end

local function clearNonLevelOverrides()
  if not FS:directoryExists(LOCAL_OVERRIDEN_ROOT) then
    return
  end

  local entries = FS:findFiles(LOCAL_OVERRIDEN_ROOT, '*', 0, true, false)
  for _, entry in ipairs(entries) do
    local entryName = entry:match("([^/]+)$")
    if entryName and entryName ~= "levels" then
      FS:remove(entry)
    end
  end
end

local function handleMapOverrides(newMapsWithOverrides)
  if #newMapsWithOverrides == 0 then
    return true
  end

  local wasMount = FS:isMounted(LOCAL_OVERRIDEN_ROOT)
  if wasMount then
    unmountCustomOverrides()
  end
  clearNonLevelOverrides()

  for _, levelName in ipairs(newMapsWithOverrides) do
    clearDirectory(LOCAL_OVERRIDEN_ROOT .. "levels/" .. levelName)
  end

  if wasMount then
    mountCustomOverrides()
  end
  return true
end

local function unloadOverrides()
  if not originalLoad then
    return false
  end

  extensions.load = originalLoad
  originalLoad = nil

  extensions.reload = originalReload
  originalReload = nil

  local pathsToClear = {}
  for path, _ in pairs(overrides) do
    table.insert(pathsToClear, path)
  end

  for _, path in ipairs(pathsToClear) do
    clearOverride(path)
  end

  unmountCustomOverrides()

  loadManualUnloadExtensions()
  reloadUI()

  return true
end

local function onModDeactivated(modData)
  if not ourMod then
    return
  end

  if (ourMod.name and modData.modname == ourMod.name) or
    (ourMod.id and modData.modData and modData.modData.tagid == ourMod.id) then
    print('Unloading overrides')
    unloadOverrides()
  end
end

local applyMarkerInteractionOverride
local markerInteractionOverrideApplied = false
local markerInteractionRetryTimer = 0

local function onExtensionLoaded()
  ourMod = overhaul_extensionManager.getModData()
  installSystem()
  -- Keep the console out of the Lua-reload snapshot before dropping it. On Ctrl+L it
  -- would otherwise be restored as part of the extension batch and then unloaded again
  -- right here, mid-batch, which vanilla reports as
  --   "could not reload extension after Lua reload: ui_console".
  -- Excluding it makes a reload land in the same state as a cold boot: console unloaded,
  -- re-requiring against the installed overrides the next time it is opened.
  extensions.disableSerialization("ui_console")
  extensions.unload("ui_console")

  -- This extension commonly loads after both onClientStartMission and career's
  -- module-only onCareerActivated pass. Apply immediately when joining an
  -- already-active career; onUpdate retries briefly if markerInteraction is not
  -- live yet.
  if career_career and career_career.isActive and career_career.isActive() then
    applyMarkerInteractionOverride()
  end
end

-- Apply markerInteraction after career/level is up. Boot-time EARLY_LOADED overlay
-- of this module broke load order; preload alone leaves the live vanilla table in place.
applyMarkerInteractionOverride = function()
  -- Career activate often follows a mission start that already applied us; skip re-init.
  if markerInteractionOverrideApplied then return true end

  local entry = overrides['gameplay_markerInteraction'] or overrides['gameplay/markerInteraction']
  if not entry then return false end
  if type(gameplay_markerInteraction) ~= 'table' then return false end

  package.loaded[entry.override] = nil
  local ok, replacement = xpcall(function()
    return require(entry.override)
  end, debug.traceback)
  if not ok then
    log('E', logTag, 'Deferred markerInteraction override failed:\n' .. tostring(replacement))
    return false
  end
  if type(replacement) ~= 'table' then
    log('E', logTag, 'Deferred markerInteraction override did not return a table')
    return false
  end

  local live = gameplay_markerInteraction
  for key, value in pairs(replacement) do
    live[key] = value
  end
  refreshLiveHooks(replacement)
  package.loaded[entry.convertedFormat] = live
  package.loaded['/lua/ge/extensions/' .. entry.convertedFormat] = live
  package.loaded['ge/extensions/' .. entry.convertedFormat] = live

  if type(replacement.onExtensionLoaded) == 'function' then
    local initOk, initErr = xpcall(replacement.onExtensionLoaded, debug.traceback)
    if not initOk then
      log('E', logTag, 'Deferred markerInteraction onExtensionLoaded failed:\n' .. tostring(initErr))
      return false
    end
  end

  if live.setForceReevaluateOpenPrompt then
    live.setForceReevaluateOpenPrompt()
  end
  markerInteractionOverrideApplied = true
  log('I', logTag, 'Applied deferred gameplay_markerInteraction override')
  return true
end

local function onCareerActivated()
  applyMarkerInteractionOverride()
end

local function onCareerActive(active)
  if active then
    applyMarkerInteractionOverride()
  end
end

local function onUpdate(dtReal)
  if markerInteractionOverrideApplied then return end
  if not (career_career and career_career.isActive and career_career.isActive()) then return end

  markerInteractionRetryTimer = markerInteractionRetryTimer + (dtReal or 0)
  if markerInteractionRetryTimer < 0.5 then return end
  markerInteractionRetryTimer = 0
  applyMarkerInteractionOverride()
end

local function onClientStartMission()
  patchLiveTrafficVehicles()
  -- Level loads can revive the vanilla live table; re-apply after each mission/level start.
  markerInteractionOverrideApplied = false
  applyMarkerInteractionOverride()
end

local function onTrafficStarted()
  patchLiveTrafficVehicles()
end

local function onTrafficVehicleAdded(id)
  patchTrafficVehicleObject(id)
end

M.onExtensionLoaded = onExtensionLoaded
M.onModDeactivated = onModDeactivated
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onClientStartMission = onClientStartMission
M.onUpdate = onUpdate
M.onTrafficStarted = onTrafficStarted
M.onTrafficVehicleAdded = onTrafficVehicleAdded

M.handleMapOverrides = handleMapOverrides
M.patchLiveTrafficVehicles = patchLiveTrafficVehicles
M.ensureMarkerInteractionOverride = applyMarkerInteractionOverride

return M
