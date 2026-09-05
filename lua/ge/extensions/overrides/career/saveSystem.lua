-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local saveRoot = 'settings/cloud/saves/'
local saveSystemVersion = 64
local backwardsCompVersion = 36
local numberOfAutosaves = 3
local creationDateOfCurrentProfile
local queueSave = false
local saveInProgress = false
local pendingForceSave = false
local pendingSaveName = nil
local pendingVehiclesThumbnailUpdate

local currentProfile
local currentSavePath
local currentDisplayName

local ffbDisabledForSave = false
local ffbVehId = nil -- vehicle we disabled FFB on; restore must target the same one
local ffbSettleFrames = 0
local ffbRestoreFrames = 0
local FFB_SETTLE_DELAY = 20
local FFB_RESTORE_DELAY = 10

local AUTOSAVE_INTERVAL_S = 300
local AUTOSAVE_MAX_SPEED = 2
local SAVE_IN_FLIGHT_TIMEOUT_S = 45
local lastAutosaveAt = 0
local saveStartedAt = 0
local preSaveInfoBackup = nil
local preSaveInfoExisted = false
local simPaused = false

local DEFER_AUTOSAVE_ROUTES = {
  ["career.computer.partShopping"] = true,
  ["career.computer.tuning"] = true,
  ["career.computer.painting"] = true,
  ["career.computer.partInventory"] = true,
}
-- Captured when a save begins so a late async completion cannot overwrite
-- the active profile's currentSavePath after a profile switch.
local saveInFlightProfile = nil
local saveInFlightPath = nil

local function autosaveIntervalReady()
  if lastAutosaveAt <= 0 then
    return true
  end
  return (os.time() - lastAutosaveAt) >= AUTOSAVE_INTERVAL_S
end

local function markAutosaveDone()
  lastAutosaveAt = os.time()
end

-- Missing player vehicle is not "stopped": spawn/swap frames would otherwise
-- arm a deferred save that then flushes at speed after FFB settle.
local function playerIsNearlyStopped()
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then
    return false
  end
  return playerVeh:getVelocity():length() < AUTOSAVE_MAX_SPEED
end

local function getCurrentUiRouteName()
  if not (ui_router and ui_router.getState) then return nil end
  local ok, state = pcall(ui_router.getState)
  if not ok or type(state) ~= "table" or type(state.currentRoute) ~= "table" then
    return nil
  end
  local entry = state.currentRoute
  if entry.request and type(entry.request.name) == "string" then
    return entry.request.name
  end
  if entry.resolved and type(entry.resolved.screenId) == "string" then
    return entry.resolved.screenId
  end
  return nil
end

local function shouldDeferAutosave()
  if simPaused then
    return true
  end
  if career_modules_partShopping and career_modules_partShopping.isShoppingSessionActive
      and career_modules_partShopping.isShoppingSessionActive() then
    return true
  end
  local routeName = getCurrentUiRouteName()
  if routeName and DEFER_AUTOSAVE_ROUTES[routeName] then
    return true
  end
  if core_gamestate then
    if core_gamestate.getLoadingStatus("careerLoading") or core_gamestate.getLoadingStatus("careerActivate") then
      return true
    end
  end
  return false
end

local function getAllSaveFolders(profile)
  local res = {}
  local folders = FS:directoryList(saveRoot .. profile, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    local data = jsonReadFile(dir .. filename .. "/info.json")
    if data then
      data.name = filename
      table.insert(res, data)
    end
  end

  table.sort(res, function(a,b) return a.date < b.date end)
  return res
end

local function pickSaveByDate(folders, oldest)
  local resultDate = oldest and "A" or "0"
  local resultSave = ""
  for i = 1, tableSize(folders) do
    local folder = folders[i]
    local data = jsonReadFile(folder .. "/info.json")
    if oldest then
      if not data or not data.date or data.date < resultDate or data.corrupted then
        resultSave = folder
        resultDate = (data and not data.corrupted) and data.date or "0"
      end
    else
      if data and data.date and data.date > resultDate and not data.corrupted then
        resultSave = folder
        resultDate = data.date
      end
    end
  end
  return resultSave
end

local function getOldestAutosave(path)
  local folders = FS:directoryList(path, false, true)

  local existingAutosaves = {}
  for i = 1, tableSize(folders) do
    local name = string.match(folders[i], "([^/\\]+)$")
    if name and string.match(name, "^autosave%d+$") then
      existingAutosaves[name] = folders[i]
    end
  end

  for i = 1, numberOfAutosaves do
    if not existingAutosaves["autosave" .. i] then
      return "/" .. path .. "/autosave" .. i
    end
  end

  local autosaveFolders = {}
  for i = 1, numberOfAutosaves do
    if existingAutosaves["autosave" .. i] then
      table.insert(autosaveFolders, existingAutosaves["autosave" .. i])
    end
  end
  return pickSaveByDate(autosaveFolders, true)
end

local function getNewestSave(path)
  local folders = FS:directoryList(path, false, true)
  return pickSaveByDate(folders, false)
end

local function isLegalDirectoryName(name)
  return not string.match(name, '[<>:"/\\|?*]')
end

local function getUsedProfileNames()
  local usedNames = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    usedNames[string.lower(filename)] = true
  end
  return usedNames
end

local function getSanitizedProfileName(profileName)
  local usedNames = getUsedProfileNames()
  local sanitizedName = string.lower(profileName or '')
  sanitizedName = string.gsub(sanitizedName, '[^a-z0-9]', '')
  if sanitizedName == '' then
    sanitizedName = 'profile'
  end

  local candidate = sanitizedName
  local counter = 1
  while usedNames[string.lower(candidate)] do
    candidate = sanitizedName .. counter
    counter = counter + 1
  end
  return candidate
end

local function setProfile(profile, specificSaveFolder)
  extensions.hook("onBeforeSetProfile")
  if not profile then
    currentSavePath = nil
    currentProfile = nil
    currentDisplayName = nil
    creationDateOfCurrentProfile = nil
    extensions.hook("onSetProfile", nil, nil)
    return false
  end
  local savePath = specificSaveFolder and (saveRoot .. profile .. "/" .. specificSaveFolder) or getNewestSave(saveRoot .. profile)

  if (not savePath or savePath == "") and not specificSaveFolder then
    savePath = saveRoot .. profile .. "/autosave1"
  end

  local data = jsonReadFile(savePath .. "/info.json")
  if data then
    if not data.version or M.getBackwardsCompVersion() > data.version then
      return false
    end
    creationDateOfCurrentProfile = data.creationDate
    currentDisplayName = data.displayName or profile
  else
    currentDisplayName = profile
    profile = getSanitizedProfileName(profile)
    savePath = specificSaveFolder and (saveRoot .. profile .. "/" .. specificSaveFolder) or getNewestSave(saveRoot .. profile)
    if not savePath or savePath == "" then
      savePath = saveRoot .. profile .. "/autosave1"
    end
    creationDateOfCurrentProfile = nil
  end

  currentSavePath = savePath
  currentProfile = profile
  lastAutosaveAt = os.time()
  queueSave = false

  extensions.hook("onSetProfile", currentSavePath, profile)
  return true
end

local function removeProfile(profile)
  if currentProfile == profile then
    if not career_career.isActive() then
      setProfile(nil)
      FS:directoryRemove(saveRoot .. profile)
    end
  else
    FS:directoryRemove(saveRoot .. profile)
  end
end

local function removeSaveFolder(profile, saveFolderName)
  if not profile or not saveFolderName or saveFolderName == "" then return false end
  if not isLegalDirectoryName(saveFolderName) then return false end

  local folderPath = saveRoot .. profile .. "/" .. saveFolderName
  if not FS:directoryExists(folderPath) then return false end

  if currentProfile == profile and currentSavePath then
    local currentFolderName = string.match(currentSavePath, "([^/\\]+)$")
    if currentFolderName == saveFolderName then return false end
  end

  FS:directoryRemove(folderPath)
  return true
end

local function renameFolderRec(oldName, newName, oldNameLength)
  local success = true
  local folders = FS:directoryList(oldName, true, true)
  for i = 1, tableSize(folders) do
    if FS:directoryExists(folders[i]) then
      if not renameFolderRec(folders[i], newName, oldNameLength) then
        success = false
      end
    else
      local newPath = string.sub(folders[i], oldNameLength + 2)
      newPath = newName .. newPath
      if FS:renameFile(folders[i], newPath) == -1 then
        success = false
      end
    end
  end
  return success
end

local function renameFolder(oldName, newName)
  local oldNameLength = string.len(oldName)
  if renameFolderRec(oldName, newName, oldNameLength) then
    FS:directoryRemove(oldName)
    return true
  end
end

local updateProfileDisplayName

local function renameProfile(profile, newName)
  if type(profile) ~= "string" or type(newName) ~= "string" or newName == ""
  or not isLegalDirectoryName(profile) or not isLegalDirectoryName(newName)
  or not FS:directoryExists(saveRoot .. profile)
  or FS:directoryExists(saveRoot .. newName) then
    return false
  end

  local renamed = false
  if currentProfile == profile then
    if not career_career.isActive() then
      setProfile(nil)
      renamed = renameFolder(saveRoot .. profile, saveRoot .. newName)
    end
  else
    renamed = renameFolder(saveRoot .. profile, saveRoot .. newName)
  end

  if not renamed then return false end
  return updateProfileDisplayName(newName, newName)
end

local function getCurrentProfile()
  return currentProfile, currentSavePath
end

local function getCurrentDisplayName()
  return currentDisplayName
end

local syncSaveExtensionsDone
local asyncSaveExtensions = {}
local saveGeneration = 0
local activeSaveGeneration = 0
local inFlightSaveName = nil
local inFlightForceSave = false
local inFlightVehiclesThumbnailUpdate
local infoData
local saveDate
local oldestSave
local pendingSaveSuccessSound = false

local function saveFailed()
  infoData = nil
end

local function jsonWriteFileSafe(filename, obj, pretty, numberPrecision, tempFileName)
  -- A nil/non-table payload used to call saveFailed() and leave info.json stuck at
  -- corrupted=true (one bad module nukes the whole autosave stamp). Soft-skip instead:
  -- keep the prior file on disk, log the symptom+stack, and let the rest of the save finish.
  if type(obj) ~= "table" then
    log("E", "save", string.format(
      "jsonWriteFileSafe: refusing non-table (%s) for %s — leaving prior file intact",
      type(obj), tostring(filename)))
    log("E", "save", debug.traceback())
    return true
  end
  tempFileName = tempFileName or filename..".tmp"
  if jsonWriteFile(tempFileName, obj, pretty, numberPrecision) then
    if FS:renameFile(tempFileName, filename) == 0 then
      return true
    else
      log("E", "save", "failed to copy temporary json!")
    end
  else
    log("E", "save", "failed to write json!")
  end
  saveFailed()
  return false
end

-- A profile's visible name lives in every save folder's info.json. Folder-only
-- copies and renames otherwise keep showing the source profile's old name.
updateProfileDisplayName = function(profile, displayName)
  local folders = FS:directoryList(saveRoot .. profile, false, true)
  for i = 1, tableSize(folders) do
    local infoPath = folders[i] .. "/info.json"
    local data = jsonReadFile(infoPath)
    if data then
      data.displayName = displayName
      if not jsonWriteFileSafe(infoPath, data, true) then
        log("E", "save", "failed to update profile display name in " .. infoPath)
        return false
      end
    end
  end
  return true
end

local function getFFBConfigForVeh(veh)
  local result = {}
  for _, action in ipairs({"steering", "accelerate", "brake"}) do
    local FFBID = veh:getFFBID(action)
    if FFBID >= 0 then
      local configStr = be:getFFBConfig(FFBID)
      local ok, ffbConfig = pcall(json.decode, configStr)
      if ok and ffbConfig then
        local ok2, ffbParams = pcall(json.decode, ffbConfig.ffbParamsJson)
        if ok2 and ffbParams then
          ffbConfig.ffbParams = ffbParams
          ffbConfig.FFBID = FFBID
          result[action] = ffbConfig
        end
      end
    end
  end
  return result
end

local function restoreFFBActual()
  -- Restore on the vehicle we actually disabled, not whatever the player is in now.
  -- A save spans many frames and career swaps the player vehicle constantly (entering,
  -- teleporting, walk<->drive via the unicycle), so be:getPlayerVehicle(0) can easily
  -- be a different -- or still-spawning -- car by the time this runs.
  local veh = ffbVehId and be:getObjectByID(ffbVehId) or nil
  if veh then
    -- These chunks execute in the vehicle's own Lua VM, which may still be booting:
    -- input_haptics is only loaded partway through lua/vehicle/main.lua. Vanilla
    -- hydros.onFFBConfigChanged indexes it unguarded, and an error inside a queued
    -- chunk is a FATAL for that VM -- the vehicle loses electrics, controls and input
    -- until it respawns. Guard inside the chunk, where the state actually lives.
    veh:queueLuaCommand("if hydros then hydros.enableFFB = true end")
    local ffbConfig = getFFBConfigForVeh(veh)
    if ffbConfig and next(ffbConfig) then
      veh:queueLuaCommand("if hydros and input_haptics then hydros.onFFBConfigChanged("..serialize(ffbConfig)..") end")
    end
  end
  ffbVehId = nil
  ffbDisabledForSave = false
end

local function restoreFFB()
  if not ffbDisabledForSave then return end
  ffbRestoreFrames = FFB_RESTORE_DELAY
end

local saveCurrentActual
local tryStartPendingSave
local mergeVehiclesThumbnailUpdate
local restorePreSaveInfo
local abortSaveInFlight

restorePreSaveInfo = function()
  if oldestSave then
    local infoPath = oldestSave .. "/info.json"
    if preSaveInfoBackup then
      jsonWriteFileSafe(infoPath, preSaveInfoBackup, true)
    elseif not preSaveInfoExisted and FS:fileExists(infoPath) then
      FS:removeFile(infoPath)
    end
  end
  preSaveInfoBackup = nil
  preSaveInfoExisted = false
end

abortSaveInFlight = function(reason)
  log("E", "saveSystem", "Aborting stuck save: " .. tostring(reason))
  restorePreSaveInfo()
  saveGeneration = saveGeneration + 1
  table.clear(asyncSaveExtensions)
  saveInProgress = false
  saveStartedAt = 0
  infoData = nil
  syncSaveExtensionsDone = false
  mergeVehiclesThumbnailUpdate(inFlightVehiclesThumbnailUpdate)
  inFlightVehiclesThumbnailUpdate = nil
  if inFlightSaveName then
    pendingSaveName = inFlightSaveName
    pendingForceSave = true
  elseif inFlightForceSave then
    pendingForceSave = true
  end
  inFlightSaveName = nil
  inFlightForceSave = false
  queueSave = true
  restoreFFB()
  extensions.hook("onCareerSaveFailed", oldestSave)
end

local function isSaveBusy()
  return saveInProgress or queueSave or ffbSettleFrames > 0
end

local function saveCompleted()
  local hasQueued = queueSave
  local forceFollowUp = pendingForceSave or (pendingSaveName ~= nil)
  local startFollowUpNow = hasQueued and forceFollowUp

  local playSuccessSound = pendingSaveSuccessSound and not startFollowUpNow
  if not startFollowUpNow then
    pendingSaveSuccessSound = false
  end

  saveInProgress = false
  saveStartedAt = 0
  inFlightVehiclesThumbnailUpdate = nil

  if infoData then
    infoData.corrupted = nil
    infoData.date = saveDate
    if jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
      if playSuccessSound then
        guihooks.trigger("toastrMsg", {type="success", title=_tr("ui.career.save.toast.success.title"), msg=""})
      end
      log("I", "Saved to " .. oldestSave)
      if saveInFlightProfile == currentProfile and saveInFlightPath == oldestSave then
        currentSavePath = oldestSave
      else
        log("W", "saveSystem", string.format(
          "Skipping currentSavePath update from stale save (inFlight=%s/%s active=%s/%s)",
          tostring(saveInFlightProfile), tostring(saveInFlightPath),
          tostring(currentProfile), tostring(currentSavePath)))
      end
      markAutosaveDone()
      preSaveInfoBackup = nil
      preSaveInfoExisted = false
      if startFollowUpNow then
        tryStartPendingSave()
        if not saveInProgress and ffbSettleFrames == 0 then
          restoreFFB()
        end
      else
        restoreFFB()
        if playSuccessSound then
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Drift_Combo_5x')
        end
        extensions.hook("onSaveFinished")
      end
      return
    end
  end

  restoreFFB()
  restorePreSaveInfo()
  guihooks.trigger("toastrMsg", {type="error", title=_tr("ui.career.save.toast.failed.title"), msg=_tr("ui.career.save.toast.failed.msg")})
  log("E", "Saving to " .. oldestSave ..  " failed!")
  extensions.hook("onCareerSaveFailed", oldestSave)
  if startFollowUpNow then
    tryStartPendingSave()
  end
end

local function registerAsyncSaveExtension(extName)
  asyncSaveExtensions[extName] = activeSaveGeneration
  return activeSaveGeneration
end

local function isAsyncSaveExtensionCurrent(extName, generation)
  return generation ~= nil and generation == activeSaveGeneration and asyncSaveExtensions[extName] == generation
end

local function asyncSaveExtensionFinished(extName, generation)
  if not isAsyncSaveExtensionCurrent(extName, generation) then
    return
  end
  asyncSaveExtensions[extName] = nil
  if saveInProgress and syncSaveExtensionsDone and tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

local function disableFFBForSave()
  if saveInProgress then return end
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then
    return
  end
  ffbVehId = playerVeh:getID()
  playerVeh:queueLuaCommand("if hydros then hydros.destroy(); hydros.enableFFB = false end")
  ffbDisabledForSave = true
  ffbSettleFrames = FFB_SETTLE_DELAY
end

local function beginQueuedSave()
  local name = pendingSaveName
  local force = pendingForceSave
  local vehiclesThumbnailUpdate = pendingVehiclesThumbnailUpdate
  pendingVehiclesThumbnailUpdate = nil
  pendingSaveName = nil
  pendingForceSave = false
  queueSave = false
  saveCurrentActual(vehiclesThumbnailUpdate, name, force or name ~= nil)
end

tryStartPendingSave = function()
  if not queueSave or saveInProgress or ffbSettleFrames > 0 then return end
  if pendingForceSave or pendingSaveName then
    beginQueuedSave()
    return
  end
  if shouldDeferAutosave() then
    return
  end
  if playerIsNearlyStopped() then
    disableFFBForSave()
  end
end

local function isTutorialBlockingSave()
  if career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive() then
    return true
  end
  return false
end

saveCurrentActual = function(vehiclesThumbnailUpdate, saveName, forceSave)
  if not currentProfile or isTutorialBlockingSave() then return end
  if saveInProgress then
    queueSave = true
    mergeVehiclesThumbnailUpdate(vehiclesThumbnailUpdate)
    if saveName then
      pendingSaveName = saveName
      pendingForceSave = true
    elseif forceSave then
      pendingForceSave = true
    end
    return
  end
  saveInProgress = true
  saveStartedAt = os.time()
  saveGeneration = saveGeneration + 1
  activeSaveGeneration = saveGeneration
  table.clear(asyncSaveExtensions)
  inFlightSaveName = saveName
  inFlightForceSave = forceSave == true or saveName ~= nil
  inFlightVehiclesThumbnailUpdate = vehiclesThumbnailUpdate
  if saveName then
    oldestSave = saveRoot .. currentProfile .. "/" .. saveName
  else
    oldestSave = getOldestAutosave(saveRoot .. currentProfile)
  end
  local infoPath = oldestSave .. "/info.json"
  preSaveInfoExisted = FS:fileExists(infoPath)
  preSaveInfoBackup = preSaveInfoExisted and jsonReadFile(infoPath) or nil
  saveInFlightProfile = currentProfile
  saveInFlightPath = oldestSave
  saveDate = os.date("!%Y-%m-%dT%H:%M:%SZ")

  infoData = {}
  infoData.version = saveSystemVersion
  infoData.date = "0"
  creationDateOfCurrentProfile = creationDateOfCurrentProfile or saveDate
  infoData.creationDate = creationDateOfCurrentProfile
  infoData.displayName = currentDisplayName
  infoData.corrupted = true

  if not jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
    saveFailed()
    saveCompleted()
    return
  end

  -- gameplay_statistic can hold a nil career stats table after deactivate/re-activate
  -- races; recover it before modules write so one nil payload cannot stamp this slot corrupted.
  if career_modules_statisticSaveGuard and career_modules_statisticSaveGuard.ensureReady then
    career_modules_statisticSaveGuard.ensureReady("saveCurrentActual")
  end

  syncSaveExtensionsDone = false
  extensions.hook("onSaveCurrentProfileAsyncStart")
  extensions.hook("onSaveCurrentProfile", oldestSave, vehiclesThumbnailUpdate)
  syncSaveExtensionsDone = true
  if tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

mergeVehiclesThumbnailUpdate = function(incoming)
  if type(incoming) ~= "table" then return end
  pendingVehiclesThumbnailUpdate = pendingVehiclesThumbnailUpdate or {}
  for _, inventoryId in ipairs(incoming) do
    if inventoryId and not tableContains(pendingVehiclesThumbnailUpdate, inventoryId) then
      table.insert(pendingVehiclesThumbnailUpdate, inventoryId)
    end
  end
end

-- (vehiclesThumbnailUpdate, playSuccessSound|force|{opts}, saveName)
local function saveCurrent(vehiclesThumbnailUpdate, arg2, arg3)
  local force, playSuccessSound, saveName
  if type(arg2) == "table" then
    force = arg2.force
    playSuccessSound = arg2.playSuccessSound
    saveName = arg2.saveName or arg3
    mergeVehiclesThumbnailUpdate(arg2.vehiclesThumbnailUpdate or vehiclesThumbnailUpdate)
  else
    mergeVehiclesThumbnailUpdate(vehiclesThumbnailUpdate)
    if type(arg3) == "string" then
      playSuccessSound = arg2 and true or false
      saveName = arg3
    elseif arg2 == true then
      force = true
      playSuccessSound = true
    else
      playSuccessSound = arg2 and true or false
    end
  end

  if playSuccessSound then
    pendingSaveSuccessSound = true
  end
  queueSave = true
  if force or saveName then
    if saveInProgress or ffbSettleFrames > 0 then
      pendingForceSave = force and true or false
      if saveName then
        pendingSaveName = saveName
      end
      return
    end
    local vehiclesThumbnailUpdate = pendingVehiclesThumbnailUpdate
    pendingVehiclesThumbnailUpdate = nil
    pendingSaveName = nil
    pendingForceSave = false
    queueSave = false
    saveCurrentActual(vehiclesThumbnailUpdate, saveName, true)
    return
  end

  if saveInProgress or ffbSettleFrames > 0 then
    return
  end
end

local function onUpdate(dt, dtSim)
  if dtSim ~= nil then
    simPaused = dtSim == 0
  end

  if saveInProgress and saveStartedAt > 0 and (os.time() - saveStartedAt) >= SAVE_IN_FLIGHT_TIMEOUT_S then
    abortSaveInFlight("timed out after " .. tostring(SAVE_IN_FLIGHT_TIMEOUT_S) .. "s")
    return
  end

  if ffbRestoreFrames > 0 then
    ffbRestoreFrames = ffbRestoreFrames - 1
    if ffbRestoreFrames == 0 then
      restoreFFBActual()
    end
    return
  end

  if ffbSettleFrames > 0 then
    ffbSettleFrames = ffbSettleFrames - 1
    if ffbSettleFrames == 0 then
      if saveInProgress then
        queueSave = true
        return
      end
      if pendingForceSave or pendingSaveName or (playerIsNearlyStopped() and not shouldDeferAutosave()) then
        beginQueuedSave()
      else
        queueSave = true
        restoreFFB()
      end
    end
    return
  end

  if not queueSave and not saveInProgress and currentProfile then
    local autosaveOn = true
    if career_career and career_career.isAutosaveEnabled then
      autosaveOn = career_career.isAutosaveEnabled()
    end
    if autosaveOn and (not career_career or not career_career.isActive or career_career.isActive()) and autosaveIntervalReady() and not shouldDeferAutosave() then
      queueSave = true
    end
  end

  if queueSave and not saveInProgress then
    if pendingForceSave or pendingSaveName then
      tryStartPendingSave()
    elseif autosaveIntervalReady() and not shouldDeferAutosave() then
      if playerIsNearlyStopped() then
        disableFFBForSave()
      end
    end
  end
end

local function duplicateSaveSlot(slotName, newName)
  if not isLegalDirectoryName(slotName) or not isLegalDirectoryName(newName) then
    return false
  end
  if slotName == newName then
    return false
  end
  local src = saveRoot .. slotName
  local dst = saveRoot .. newName
  if not FS:directoryExists(src) or FS:directoryExists(dst) then
    return false
  end

  if currentProfile == slotName and career_career.isActive() then
    M.saveCurrent(nil, {force = true})
  end

  local files = FS:findFiles(src .. "/", "*.*", -1, true, true)
  if not files or tableSize(files) == 0 then
    return false
  end

  local ok = true
  for i = 1, tableSize(files) do
    local srcPath = files[i]
    if not FS:directoryExists(srcPath) then
      local dstPath = dst .. string.sub(srcPath, #src + 2)
      local parentDir = path.split(dstPath)
      if parentDir and parentDir ~= "" and not FS:directoryExists(parentDir) then
        FS:directoryCreate(parentDir, true)
      end
      if FS:copyFile(srcPath, dstPath) ~= 0 then
        ok = false
        break
      end
    end
  end

  if not ok then
    FS:directoryRemove(dst)
    return false
  end

  if not updateProfileDisplayName(newName, newName) then
    FS:directoryRemove(dst)
    return false
  end
  return true
end

local function getAllProfiles()
  local res = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    table.insert(res, filename)
  end
  return res
end

local function onExtensionLoaded()
end

local function getSaveRootDirectory()
  return saveRoot
end

local function onSerialize()
  local data = {}
  data.currentProfile = currentProfile
  data.currentSavePath = currentSavePath
  data.currentDisplayName = currentDisplayName
  data.creationDateOfCurrentProfile = creationDateOfCurrentProfile
  return data
end

local function onDeserialized(v)
  currentProfile = v.currentProfile or v.currentSaveSlot
  currentSavePath = v.currentSavePath
  currentDisplayName = v.currentDisplayName or currentProfile
  creationDateOfCurrentProfile = v.creationDateOfCurrentProfile or v.creationDateOfCurrentSaveSlot
  lastAutosaveAt = os.time()
end

local function getSaveSystemVersion()
  return saveSystemVersion
end

local function getBackwardsCompVersion()
  return backwardsCompVersion
end

M.setProfile = setProfile
M.removeProfile = removeProfile
M.removeSaveFolder = removeSaveFolder
M.renameProfile = renameProfile
M.duplicateSaveSlot = duplicateSaveSlot
M.getCurrentProfile = getCurrentProfile
M.getCurrentDisplayName = getCurrentDisplayName
M.saveCurrent = saveCurrent
M.isSaveBusy = isSaveBusy
M.getAllProfiles = getAllProfiles
M.getSaveRootDirectory = getSaveRootDirectory
M.getNewestSave = getNewestSave
M.getAllSaveFolders = getAllSaveFolders
M.getSaveSystemVersion = getSaveSystemVersion
M.getBackwardsCompVersion = getBackwardsCompVersion
M.saveFailed = saveFailed
M.registerAsyncSaveExtension = registerAsyncSaveExtension
M.isAsyncSaveExtensionCurrent = isAsyncSaveExtensionCurrent
M.asyncSaveExtensionFinished = asyncSaveExtensionFinished
M.jsonWriteFileSafe = jsonWriteFileSafe
M.onUpdate = onUpdate

-- Compat aliases for overhaul modules still on SaveSlot names
M.setSaveSlot = setProfile
M.removeSaveSlot = removeProfile
M.renameSaveSlot = renameProfile
M.getCurrentSaveSlot = getCurrentProfile
M.getAllSaveSlots = getAllProfiles
M.getAllAutosaves = getAllSaveFolders

M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
