local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local SAVE_FILE = "maintenanceMode.json"

local enabled = false
local saveData = {enabled = false}

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

local function broadcastState()
  if career_career then
    career_career.experimentalMaintenanceEnabled = enabled
  end
  extensions.hook("onExperimentalMaintenanceModeChanged", enabled)
end

local function saveModeData(currentSavePath)
  local savePath = currentSavePath or getCurrentSavePath()
  if not savePath then return end

  ensureSaveDirectory(savePath)
  saveData.enabled = enabled == true
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), saveData, true)
end

local function setEnabled(value, skipSave)
  enabled = value == true
  saveData.enabled = enabled
  if not skipSave then
    saveModeData()
  end
  broadcastState()
  return enabled
end

local function readPendingValue()
  if not career_career then
    return nil
  end

  local pendingValue = career_career.pendingExperimentalMaintenanceEnabled
  career_career.pendingExperimentalMaintenanceEnabled = nil
  return pendingValue
end

local function loadModeData(allowPendingValue)
  local savePath = getCurrentSavePath()
  if not savePath then
    enabled = false
    saveData = {enabled = false}
    broadcastState()
    return
  end

  local filePath = getSaveFilePath(savePath)
  local loadedData = jsonReadFile(filePath)
  if type(loadedData) == "table" and loadedData.enabled ~= nil then
    enabled = loadedData.enabled == true
    saveData = {enabled = enabled}
    broadcastState()
    return
  end

  local pendingValue = allowPendingValue and readPendingValue() or nil
  enabled = pendingValue == true
  saveData = {enabled = enabled}
  saveModeData(savePath)
  broadcastState()
end

local function onCareerActivated()
  if not career_career or not career_career.isActive() then
    return
  end

  loadModeData(true)
end

local function onCareerActive(active, newSave)
  if not active then
    return false
  end

  loadModeData(newSave == true)
end

M.isEnabled = function()
  return enabled == true
end
M.setEnabled = setEnabled
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = saveModeData

return M
