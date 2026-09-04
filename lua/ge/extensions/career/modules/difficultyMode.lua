local M = {}

M.dependencies = {'career_career'}

local persist = require('ge/extensions/career/modules/difficultyModePersist')

local DIFFICULTY_MODES = {
  easy = {rewardMultiplier = 3.0, xpMultiplier = 2.0, startingCapital = 25000},
  normal = {rewardMultiplier = 1.0, xpMultiplier = 1.0, startingCapital = 15000},
  hard = {rewardMultiplier = 0.5, xpMultiplier = 0.5, startingCapital = 10000},
  hardcore = {rewardMultiplier = 0.5, xpMultiplier = 0.25, startingCapital = 0},
}

local mode = "normal"
local modeData = {}
local branchAttributeKeys = nil

local function resolveMode(candidate)
  return persist.resolveMode(candidate, false)
end

local function isChallengeActive()
  if not career_challengeModes or not career_challengeModes.isChallengeActive then
    return false
  end
  return career_challengeModes.isChallengeActive() == true
end

local function getCurrentSavePath()
  local _, savePath = career_saveSystem.getCurrentProfile()
  return savePath
end

local function getModeConfig(modeName)
  return DIFFICULTY_MODES[resolveMode(modeName)] or DIFFICULTY_MODES.normal
end

local function normalizePositiveMultiplier(value)
  if type(value) ~= "number" or value <= 0 then
    return nil
  end
  return value
end

local function normalizeStartingCapital(value)
  if type(value) ~= "number" or value < 0 then
    return nil
  end
  return math.floor(value + 0.5)
end

-- Only touch keys that are explicitly present so partial override tables do not
-- wipe previously saved custom values. Invalid inputs leave the saved value alone.
local function applyOverridesToModeData(overrides)
  if type(overrides) ~= "table" then
    return
  end

  if rawget(overrides, "rewardMultiplier") ~= nil then
    local normalized = normalizePositiveMultiplier(overrides.rewardMultiplier)
    if normalized ~= nil then
      modeData.rewardMultiplier = normalized
    end
  end

  if rawget(overrides, "xpMultiplier") ~= nil then
    local normalized = normalizePositiveMultiplier(overrides.xpMultiplier)
    if normalized ~= nil then
      modeData.xpMultiplier = normalized
    end
  end

  if rawget(overrides, "startingCapital") ~= nil then
    local normalized = normalizeStartingCapital(overrides.startingCapital)
    if normalized ~= nil then
      modeData.startingCapital = normalized
    end
  end
end

local function getEffectiveRewardMultiplier()
  local override = normalizePositiveMultiplier(modeData.rewardMultiplier)
  if override then
    return override
  end
  return getModeConfig(mode).rewardMultiplier
end

local function getEffectiveXPMultiplier()
  local override = normalizePositiveMultiplier(modeData.xpMultiplier)
  if override then
    return override
  end
  return getModeConfig(mode).xpMultiplier
end

local function getEffectiveStartingCapital()
  local override = normalizeStartingCapital(modeData.startingCapital)
  if override ~= nil then
    return override
  end
  return getModeConfig(mode).startingCapital
end

local function publishHardcoreFlag()
  persist.publishHardcoreFlag(mode == "hardcore")
end

local function cacheBranchAttributeKeys()
  if branchAttributeKeys ~= nil then
    return branchAttributeKeys
  end
  branchAttributeKeys = {}
  for _, branch in ipairs(career_branches.getSortedBranches() or {}) do
    if type(branch.attributeKey) == "string" and branch.attributeKey ~= "" then
      branchAttributeKeys[branch.attributeKey] = true
    end
  end
  return branchAttributeKeys
end

local function isProgressionKey(key)
  if type(key) ~= "string" then return false end
  if key == "beamXP" then return true end
  if key:endswith("Reputation") then return true end
  if cacheBranchAttributeKeys()[key] then return true end
  return false
end

local function saveModeData(currentSavePath)
  local savePath = currentSavePath or getCurrentSavePath()
  if not savePath then return end

  modeData.mode = resolveMode(modeData.mode or mode)
  modeData.lastModified = os.time()
  -- Also syncs legacy hardcore.json for older profile readers.
  persist.writeModeDataTable(savePath, modeData)
end

local function loadModeData()
  modeData = {mode = "normal"}
  if not career_career or not career_career.isActive() then
    mode = "normal"
    return
  end

  local savePath = getCurrentSavePath()
  if not savePath then
    mode = resolveMode(career_career.hardcoreMode and "hardcore" or "normal")
    modeData.mode = mode
    publishHardcoreFlag()
    return
  end

  local saveData = jsonReadFile(persist.getSaveFilePath(savePath))
  if type(saveData) == "table" and next(saveData) then
    modeData = saveData
    modeData.mode = resolveMode(modeData.mode)
    mode = modeData.mode
    publishHardcoreFlag()
    return
  end

  local legacyData = jsonReadFile(persist.getLegacyHardcorePath(savePath))
  if type(legacyData) == "table" and legacyData.hardcoreMode == true then
    mode = "hardcore"
  elseif career_career.hardcoreMode then
    mode = "hardcore"
  else
    mode = "normal"
  end

  modeData.mode = mode
  publishHardcoreFlag()
  saveModeData(savePath)
end

local function applyEconomyPreset(modeName, force)
  if not force and not M.isDifficultyActive() then
    return false
  end
  if career_modules_economyAdjusterPolicy and career_modules_economyAdjusterPolicy.rebuild then
    return career_modules_economyAdjusterPolicy.rebuild()
  end
  if not career_economyAdjuster or not career_economyAdjuster.getAvailableTypes then
    return false
  end

  local rewardMultiplier = getEffectiveRewardMultiplier()
  local availableTypes = career_economyAdjuster.getAvailableTypes() or {}
  if #availableTypes == 0 then
    return false
  end

  local multipliers = {}
  for _, typeName in ipairs(availableTypes) do
    multipliers[typeName] = rewardMultiplier
  end

  if career_economyAdjuster.setAllTypeMultipliers then
    career_economyAdjuster.setAllTypeMultipliers(multipliers)
    return true
  end
  return false
end

local function setMode(newMode, skipSave, overrides)
  local resolvedMode = resolveMode(newMode)
  mode = resolvedMode
  modeData.mode = resolvedMode
  if type(overrides) == "table" then
    applyOverridesToModeData(overrides)
  end
  publishHardcoreFlag()
  if not skipSave then
    saveModeData()
  end

  extensions.hook("onHardcoreModeChanged", resolvedMode == "hardcore")
  applyEconomyPreset(resolvedMode)
  return resolvedMode
end

local function scaleNumeric(value, multiplier)
  if type(value) ~= "number" then return value end
  if value <= 0 then return value end
  return value * multiplier
end

local function getXpMultiplierForProgressionKey(key)
  if career_modules_xpAdjusterPolicy and career_modules_xpAdjusterPolicy.getEffectiveMultiplierForKey then
    return career_modules_xpAdjusterPolicy.getEffectiveMultiplierForKey(key)
  end
  return M.getXPMultiplier()
end

local function scaleFlatRewards(rewardTable, options)
  local opts = options or {}
  local includeMoney = opts.includeMoney == true
  if not M.isDifficultyActive() then
    return rewardTable
  end

  local rewardMultiplier = M.getRewardMultiplier()
  for key, amount in pairs(rewardTable or {}) do
    if type(amount) == "number" and amount > 0 then
      if key == "money" and includeMoney then
        rewardTable[key] = scaleNumeric(amount, rewardMultiplier)
      elseif isProgressionKey(key) then
        rewardTable[key] = scaleNumeric(amount, getXpMultiplierForProgressionKey(key))
      end
    end
  end
  return rewardTable
end

local function scalePaymentRewardData(rewardData, options)
  local opts = options or {}
  local includeMoney = opts.includeMoney == true
  if not M.isDifficultyActive() then
    return rewardData
  end

  local rewardMultiplier = M.getRewardMultiplier()
  for key, info in pairs(rewardData or {}) do
    if type(info) == "table" and type(info.amount) == "number" and info.amount > 0 then
      if key == "money" and includeMoney then
        info.amount = scaleNumeric(info.amount, rewardMultiplier)
      elseif isProgressionKey(key) then
        info.amount = scaleNumeric(info.amount, getXpMultiplierForProgressionKey(key))
      end
    end
  end
  return rewardData
end

local function onCareerActivated()
  loadModeData()
  branchAttributeKeys = nil
  publishHardcoreFlag()
  extensions.hook("onHardcoreModeChanged", M.isHardcoreMode())
  applyEconomyPreset(mode)
end

local function onCareerActive(active)
  if not active then
    return
  end
  loadModeData()
  branchAttributeKeys = nil
  publishHardcoreFlag()
  extensions.hook("onHardcoreModeChanged", M.isHardcoreMode())
  applyEconomyPreset(mode)
end

local function onChallengeModeStateChanged(isActive)
  if isActive then
    return true
  end
  return applyEconomyPreset(mode, true)
end

M.getModes = function() return deepcopy(DIFFICULTY_MODES) end
M.getMode = function() return mode end
M.setMode = setMode
M.getRewardMultiplier = function() return getEffectiveRewardMultiplier() end
M.getXPMultiplier = function() return getEffectiveXPMultiplier() end
M.getXPMultiplierForKey = getXpMultiplierForProgressionKey
M.getEconomyMultiplier = function() return M.getRewardMultiplier() end
M.getStartingCapital = function() return getEffectiveStartingCapital() end
M.applyOverrides = applyOverridesToModeData
M.isHardcoreMode = function() return mode == "hardcore" end
M.isDifficultyActive = function()
  if not career_career or not career_career.isActive() then
    return false
  end
  return not isChallengeActive()
end
M.applyEconomyPreset = applyEconomyPreset
M.scaleFlatRewards = scaleFlatRewards
M.scalePaymentRewardData = scalePaymentRewardData
M.onChallengeModeStateChanged = onChallengeModeStateChanged
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = saveModeData
M.resolveMode = resolveMode
M.saveModeData = saveModeData

return M
