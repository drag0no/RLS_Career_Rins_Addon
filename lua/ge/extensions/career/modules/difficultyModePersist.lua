-- Shared difficulty-mode save paths / schema. Plain require module (not an
-- extension) so career.lua can use it before career_modules_difficultyMode loads.

local M = {}

M.SAVE_FILE = "difficultyMode.json"
M.LEGACY_HARDCORE_FILE = "hardcore.json"
M.RELATIVE_DIR = "career/rls_career"

M.VALID_MODES = {
  easy = true,
  normal = true,
  hard = true,
  hardcore = true,
}

local function resolveMode(candidate, hardcoreFallback)
  if type(candidate) == "string" then
    local normalized = string.lower(candidate)
    if M.VALID_MODES[normalized] then
      return normalized
    end
  end
  if hardcoreFallback then
    return "hardcore"
  end
  return "normal"
end

local function getDirPath(savePath)
  return savePath .. "/" .. M.RELATIVE_DIR
end

local function getSaveFilePath(savePath)
  return getDirPath(savePath) .. "/" .. M.SAVE_FILE
end

local function getLegacyHardcorePath(savePath)
  return getDirPath(savePath) .. "/" .. M.LEGACY_HARDCORE_FILE
end

local function ensureDir(savePath)
  local dirPath = getDirPath(savePath)
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  return dirPath
end

-- Sync hardcoreMode onto career_career and the live global (overlay-safe).
local function publishHardcoreFlag(isHardcore)
  local value = isHardcore == true
  if career_career then
    career_career.hardcoreMode = value
  end
  local live = rawget(_G, "career_career")
  if live ~= nil then
    live.hardcoreMode = value
  end
end

local function readModeFromSave(savePath)
  if not savePath then
    return nil
  end
  local difficultyData = jsonReadFile(getSaveFilePath(savePath))
  if type(difficultyData) == "table" and type(difficultyData.mode) == "string" then
    return resolveMode(difficultyData.mode, false)
  end
  local hardcoreData = jsonReadFile(getLegacyHardcorePath(savePath))
  if type(hardcoreData) == "table" and hardcoreData.hardcoreMode == true then
    return "hardcore"
  end
  return nil
end

local function normalizeOverridesForPayload(overrides)
  local out = {}
  if type(overrides) ~= "table" then
    return out
  end
  if type(overrides.rewardMultiplier) == "number" and overrides.rewardMultiplier > 0 then
    out.rewardMultiplier = overrides.rewardMultiplier
  end
  if type(overrides.xpMultiplier) == "number" and overrides.xpMultiplier > 0 then
    out.xpMultiplier = overrides.xpMultiplier
  end
  if type(overrides.startingCapital) == "number" and overrides.startingCapital >= 0 then
    out.startingCapital = overrides.startingCapital
  end
  return out
end

local function writeLegacyHardcoreFlag(savePath, isHardcore)
  career_saveSystem.jsonWriteFileSafe(getLegacyHardcorePath(savePath), {
    hardcoreMode = isHardcore == true,
  }, true)
end

local function writeModeToSave(savePath, modeName, overrides)
  if not savePath or not modeName then
    return
  end
  ensureDir(savePath)
  local payload = {mode = modeName, lastModified = os.time()}
  for key, value in pairs(normalizeOverridesForPayload(overrides)) do
    payload[key] = value
  end
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), payload, true)
  writeLegacyHardcoreFlag(savePath, modeName == "hardcore")
end

-- Writes a full modeData table (runtime save from difficultyMode.lua).
local function writeModeDataTable(savePath, modeData)
  if not savePath or type(modeData) ~= "table" then
    return
  end
  ensureDir(savePath)
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), modeData, true)
  writeLegacyHardcoreFlag(savePath, modeData.mode == "hardcore")
end

M.resolveMode = resolveMode
M.getDirPath = getDirPath
M.getSaveFilePath = getSaveFilePath
M.getLegacyHardcorePath = getLegacyHardcorePath
M.ensureDir = ensureDir
M.publishHardcoreFlag = publishHardcoreFlag
M.readModeFromSave = readModeFromSave
M.writeModeToSave = writeModeToSave
M.writeModeDataTable = writeModeDataTable

return M
