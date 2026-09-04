local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'career_modules_economyAdjusterPolicy'}

local SAVE_FILE = "policePreference.json"

local enabled = true
local saveData = {enabled = true}
-- Preference written from the profile UI; applied on next career load, not mid-session.
local deferredEnabled = nil

local function getCurrentSavePath()
  local _, savePath = career_saveSystem.getCurrentProfile()
  return savePath
end

local function getSaveFilePath(savePath)
  return savePath .. "/career/rls_career/" .. SAVE_FILE
end

local function ensureSaveDirectory(savePath)
  local dirPath = savePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function applyPoliceState()
  if career_career then
    career_career.policeEnabled = enabled == true
  end

  if career_modules_economyAdjusterPolicy and career_modules_economyAdjusterPolicy.rebuild then
    career_modules_economyAdjusterPolicy.rebuild()
  end
end

local function broadcastState()
  applyPoliceState()
  extensions.hook("onPolicePreferenceChanged", enabled)
end

local function savePreferenceData(currentSavePath, overrideEnabled)
  local savePath = currentSavePath or getCurrentSavePath()
  if not savePath then return end

  ensureSaveDirectory(savePath)
  -- Only honor an explicit boolean override. Career save hooks pass
  -- (savePath, vehiclesThumbnailUpdate); treating that 2nd arg as the preference
  -- wrote enabled=false on every autosave while runtime police stayed on.
  local value
  if type(overrideEnabled) == "boolean" then
    value = overrideEnabled
  elseif deferredEnabled ~= nil then
    value = deferredEnabled
  else
    value = enabled
  end
  saveData.enabled = value == true
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), saveData, true)
end

local function onSaveCurrentProfile(currentSavePath)
  savePreferenceData(currentSavePath)
end

local function setEnabled(value, skipSave)
  deferredEnabled = nil
  enabled = value == true
  saveData.enabled = enabled
  if not skipSave then
    savePreferenceData()
  end
  broadcastState()
  return enabled
end

-- Persist preference for next load without changing mid-session police behavior.
local function setEnabledForNextLoad(value)
  deferredEnabled = value == true
  savePreferenceData(nil, deferredEnabled)
  return deferredEnabled
end

-- Seed on disk before career modules activate / first autosave. Same idea as
-- difficultyModePersist.writeModeToSave — otherwise an early onSaveCurrentProfile
-- can write the module default (enabled=true) and load then ignores pending.
local function writeEnabledToSave(savePath, value)
  if not savePath then return false end
  ensureSaveDirectory(savePath)
  local payload = {enabled = value == true}
  return career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), payload, true) == true
end

local function readPendingValue()
  if not career_career then
    return nil
  end

  local pendingValue = career_career.pendingPoliceEnabled
  career_career.pendingPoliceEnabled = nil
  return pendingValue
end

local function resolveStartingOptionsPolice()
  local options = career_career and career_career.startingOptions
  if type(options) == "table" and options.policeEnabled ~= nil then
    return options.policeEnabled == true
  end
  return nil
end

local function loadPreferenceData(allowPendingValue)
  deferredEnabled = nil
  local savePath = getCurrentSavePath()
  if not savePath then
    enabled = true
    saveData = {enabled = true}
    broadcastState()
    return
  end

  -- New-save create choice wins over any file an earlier module save may have
  -- written with the default enabled=true.
  if allowPendingValue then
    local pendingValue = readPendingValue()
    if pendingValue ~= nil then
      enabled = pendingValue == true
      saveData = {enabled = enabled}
      savePreferenceData(savePath)
      broadcastState()
      return
    end
  end

  local filePath = getSaveFilePath(savePath)
  local loadedData = jsonReadFile(filePath)
  if type(loadedData) == "table" and loadedData.enabled ~= nil then
    enabled = loadedData.enabled == true
    saveData = {enabled = enabled}
    broadcastState()
    return
  end

  local fromStarting = resolveStartingOptionsPolice()
  if fromStarting ~= nil then
    enabled = fromStarting
  else
    enabled = true
  end
  saveData = {enabled = enabled}
  savePreferenceData(savePath)
  broadcastState()
end

local function onCareerActivated()
  if not career_career or not career_career.isActive() then
    return
  end

  loadPreferenceData(true)
end

local function onCareerActive(active, newSave)
  if not active then
    return false
  end

  loadPreferenceData(newSave == true)
end

M.isEnabled = function()
  return enabled == true
end
M.getSavedEnabled = function()
  if deferredEnabled ~= nil then
    return deferredEnabled == true
  end
  return enabled == true
end
M.setEnabled = setEnabled
M.setEnabledForNextLoad = setEnabledForNextLoad
M.writeEnabledToSave = writeEnabledToSave
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
