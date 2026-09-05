local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
  'career_modules_difficultyMode',
}

local SAVE_FILE = "sandboxXpProfile.json"
local DEFAULT_RELATIVE = 1.0
local MIN_RELATIVE = 0.25
local MAX_RELATIVE = 3.0

-- Mirror economyAdjusterPolicy umbrella tree; progression keys are skill branches.
local XP_SECTIONS = {
  {id = "dirt", label = "Dirt", children = {{id = "dirt", label = "Dirt", skillKey = "careerSkills-dirt"}}},
  {id = "offroad", label = "Off-Road", children = {{id = "offroad", label = "Off-Road", skillKey = "careerSkills-offroad"}}},
  {id = "speed", label = "Speed", children = {{id = "speed", label = "Speed", skillKey = "careerSkills-speed"}}},
  {id = "mayhem", label = "Mayhem", children = {{id = "mayhem", label = "Mayhem", skillKey = "careerSkills-mayhem"}}},
  {id = "circuitRacing", label = "Circuit Racing", children = {{id = "circuitRacing", label = "Circuit Racing", skillKey = "careerSkills-circuitRacing"}}},
  {id = "emergency", label = "Emergency", children = {{id = "emergency", label = "Emergency", skillKey = "careerSkills-emergency"}}},
  {id = "passenger", label = "Passenger", children = {{id = "passenger", label = "Passenger", skillKey = "careerSkills-passenger"}}},
  {id = "operator", label = "Operator", children = {{id = "operator", label = "Operator", skillKey = "careerSkills-operator"}}},
  {id = "recovery", label = "Recovery", children = {{id = "recovery", label = "Recovery", skillKey = "careerSkills-recovery"}}},
  {id = "logistics", label = "Logistics", children = {{id = "logistics", label = "Logistics", skillKey = "logistics-delivery"}}},
  {id = "gambling", label = "Gambling", children = {{id = "gambling", label = "Gambling", skillKey = "careerSkills-gambling"}}},
  {id = "stamina", label = "Stamina", children = {{id = "stamina", label = "Stamina", skillKey = "stamina"}}},
}

local profileData = {
  umbrellas = {},
}

local skillKeyToUmbrellaId = {}
local manifestSkillKeys = {}
local initialized = false

local function clampRelative(value)
  local num = tonumber(value)
  if not num then
    return DEFAULT_RELATIVE
  end
  if num < MIN_RELATIVE then
    return MIN_RELATIVE
  end
  if num > MAX_RELATIVE then
    return MAX_RELATIVE
  end
  return num
end

local function isChallengeActive()
  if not career_challengeModes or not career_challengeModes.isChallengeActive then
    return false
  end
  return career_challengeModes.isChallengeActive() == true
end

local function getGlobalXpMultiplier()
  if career_modules_difficultyMode and career_modules_difficultyMode.getXPMultiplier then
    local value = career_modules_difficultyMode.getXPMultiplier()
    if type(value) == "number" and value > 0 then
      return value
    end
  end
  return 1.0
end

local function buildManifestIndexes()
  skillKeyToUmbrellaId = {}
  manifestSkillKeys = {}

  for _, section in ipairs(XP_SECTIONS) do
    for _, child in ipairs(section.children or {}) do
      if type(child.skillKey) == "string" and child.skillKey ~= "" then
        skillKeyToUmbrellaId[child.skillKey] = child.id
        manifestSkillKeys[child.skillKey] = true
      end
    end
  end
  initialized = true
end

local function getRelativeForSkillKey(skillKey)
  if not initialized then
    buildManifestIndexes()
  end

  if type(skillKey) ~= "string" or skillKey == "" then
    return DEFAULT_RELATIVE
  end

  local umbrellaId = skillKeyToUmbrellaId[skillKey]
  if umbrellaId and profileData.umbrellas and type(profileData.umbrellas[umbrellaId]) == "number" then
    return clampRelative(profileData.umbrellas[umbrellaId])
  end

  return DEFAULT_RELATIVE
end

local function sanitizeProfileTable(raw)
  local sanitized = { umbrellas = {} }
  if type(raw) ~= "table" then
    return sanitized
  end

  if type(raw.umbrellas) == "table" then
    for umbrellaId, value in pairs(raw.umbrellas) do
      if type(umbrellaId) == "string" and type(value) == "number" then
        local clamped = clampRelative(value)
        if math.abs(clamped - DEFAULT_RELATIVE) > 0.001 then
          sanitized.umbrellas[umbrellaId] = clamped
        end
      end
    end
  end

  return sanitized
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

local function saveProfileData(currentSavePath)
  if not career_career or not career_career.isActive() then
    return
  end

  local savePath = currentSavePath
  if not savePath then
    _, savePath = career_saveSystem.getCurrentProfile()
  end
  if not savePath then
    return
  end

  ensureSaveDirectory(savePath)
  local payload = {
    umbrellas = deepcopy(profileData.umbrellas or {}),
    lastModified = os.time(),
  }
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), payload, true)
end

local function consumePendingProfile()
  if not career_career then
    return nil
  end

  local pending = career_career.pendingSandboxXpProfile
  career_career.pendingSandboxXpProfile = nil
  M.pendingSandboxXpProfile = nil

  if type(pending) ~= "table" then
    return nil
  end
  return sanitizeProfileTable(pending)
end

local function loadProfileData(allowPending)
  local pending = allowPending and consumePendingProfile() or nil
  if pending then
    profileData = pending
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      saveProfileData(savePath)
    end
    return
  end

  local _, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then
    profileData = { umbrellas = {} }
    return
  end

  local loaded = jsonReadFile(getSaveFilePath(savePath))
  profileData = sanitizeProfileTable(loaded)
end

local function getEffectiveMultiplierForKey(progressionKey)
  if isChallengeActive() then
    return getGlobalXpMultiplier()
  end
  if not career_modules_difficultyMode or not career_modules_difficultyMode.isDifficultyActive
      or not career_modules_difficultyMode.isDifficultyActive() then
    return 1.0
  end

  local globalMultiplier = getGlobalXpMultiplier()
  local relative = getRelativeForSkillKey(progressionKey)
  return globalMultiplier * relative
end

local function getMultiplierBreakdownForKey(progressionKey)
  if isChallengeActive() then
    return {
      global = getGlobalXpMultiplier(),
      relative = DEFAULT_RELATIVE,
      effective = getGlobalXpMultiplier(),
    }
  end

  local relative = getRelativeForSkillKey(progressionKey)

  local globalMultiplier = getGlobalXpMultiplier()
  return {
    global = globalMultiplier,
    relative = relative,
    effective = globalMultiplier * relative,
  }
end

local function setProfileFromUI(rawProfile, skipSave)
  profileData = sanitizeProfileTable(rawProfile)
  if not skipSave then
    saveProfileData()
  end
  return true
end

local function getManifestForUI()
  if not initialized then
    buildManifestIndexes()
  end
  return deepcopy(XP_SECTIONS)
end

local function getProfileForUI()
  return deepcopy(profileData)
end

local function onCareerActivated()
  if not career_career or not career_career.isActive() then
    return
  end
  loadProfileData(true)
end

local function onCareerActive(active, newSave)
  if not active then
    profileData = { umbrellas = {} }
    return false
  end
  loadProfileData(newSave == true)
  return true
end

local function onSaveCurrentProfile(currentSavePath)
  saveProfileData(currentSavePath)
end

M.getEffectiveMultiplierForKey = getEffectiveMultiplierForKey
M.getMultiplierBreakdownForKey = getMultiplierBreakdownForKey
M.getManifestForUI = getManifestForUI
M.getProfileForUI = getProfileForUI
M.setProfileFromUI = setProfileFromUI
M.sanitizeProfileTable = sanitizeProfileTable
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
