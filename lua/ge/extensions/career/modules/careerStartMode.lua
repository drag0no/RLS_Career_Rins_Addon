local M = {}

M.dependencies = {'career_career'}

local saveFile = "careerStartMode.json"
local saveData = {}
local careerStartMode = nil

local VALID_MODES = {
  freeroam = true,
  story = true,
  sandbox = true,
  hardcore = true,
  career = true,
  custom = true,
}

local function resolveMode(candidate)
  if type(candidate) ~= "string" then
    return nil
  end
  local normalized = string.lower(candidate)
  if VALID_MODES[normalized] then
    return normalized
  end
  return nil
end

local function inferLegacyModeFromSave(savePath)
  if not savePath then
    return nil
  end

  local cheatsData = jsonReadFile(savePath .. "/career/rls_career/cheats.json")
  if cheatsData and cheatsData.cheatsMode then
    return "freeroam"
  end

  local challengeData = jsonReadFile(savePath .. "/career/rls_career/challengeModes.json")
  if challengeData and challengeData.activeChallenge then
    return "story"
  end

  local difficultyData = jsonReadFile(savePath .. "/career/rls_career/difficultyMode.json")
  if difficultyData and difficultyData.mode == "hardcore" then
    return "hardcore"
  end

  local hardcoreData = jsonReadFile(savePath .. "/career/rls_career/hardcore.json")
  if hardcoreData and hardcoreData.hardcoreMode then
    return "hardcore"
  end

  return nil
end

local function inferLegacyMode()
  local pendingMode = resolveMode(career_career.pendingCareerStartMode)
  if pendingMode then
    return pendingMode
  end
  if career_career.cheatsMode then
    return "freeroam"
  end
  if career_career.pendingChallengeId then
    return "story"
  end
  if career_career.hardcoreMode then
    return "hardcore"
  end
  return nil
end

local function onCareerActive(active)
  if not active then
    careerStartMode = nil
    saveData = {}
    return false
  end

  local _, savePath = career_saveSystem.getCurrentProfile()
  saveData = savePath and jsonReadFile(savePath .. "/career/rls_career/" .. saveFile) or {}

  if not next(saveData) then
    local initialMode = resolveMode(career_career.pendingCareerStartMode) or inferLegacyMode() or inferLegacyModeFromSave(savePath)
    if initialMode then
      saveData = {careerStartMode = initialMode}
      if savePath then
        local dirPath = savePath .. "/career/rls_career"
        if not FS:directoryExists(dirPath) then
          FS:directoryCreate(dirPath)
        end
        career_saveSystem.jsonWriteFileSafe(savePath .. "/career/rls_career/" .. saveFile, saveData, true)
      end
    end
  end

  careerStartMode = resolveMode(saveData.careerStartMode)
end

local function onSaveCurrentProfile(currentSavePath)
  if not careerStartMode then
    return
  end
  saveData.careerStartMode = careerStartMode
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/rls_career/" .. saveFile, saveData, true)
end

M.getCareerStartMode = function()
  return careerStartMode
end

M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
