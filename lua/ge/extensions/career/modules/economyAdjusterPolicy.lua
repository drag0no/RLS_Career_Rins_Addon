local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
  'career_economyAdjuster',
  'career_modules_difficultyMode',
}

local SAVE_FILE = "sandboxEconomyProfile.json"
local DEFAULT_RELATIVE = 1.0
local MIN_RELATIVE = 0.25
local MAX_RELATIVE = 3.0

local TYPE_ALIASES = {
  mud = "mudding",
  crawl = "crawling",
  apexracing = "roadracing",
}

-- Canonical umbrella manifest (Lua source of truth for switchboard wiring).
local ECONOMY_SECTIONS = {
  {
    id = "emergency",
    label = "Emergency",
    children = {
      { id = "police", label = "Police", skillKey = "careerSkills-emergency", economyKeys = { "police", "criminal" } },
      { id = "paramedic", label = "Paramedic", skillKey = "careerSkills-emergency", economyKeys = { "ambulance" } },
    },
  },
  {
    id = "logistics",
    label = "Logistics",
    children = {
      {
        id = "logistics",
        label = "Logistics",
        skillKey = "logistics-delivery",
        economyKeys = {
          "delivery_parcel", "delivery_vehicle", "delivery_trailer",
          "delivery_fluid", "delivery_dryBulk", "delivery_cement",
          "delivery_cash", "beamEats",
        },
        expandable = {
          "delivery_parcel", "delivery_vehicle", "delivery_trailer",
          "delivery_fluid", "delivery_dryBulk", "delivery_cement",
          "delivery_cash", "beamEats",
        },
      },
    },
  },
  {
    id = "jobs",
    label = "Passenger, Operator & Recovery",
    children = {
      { id = "bus", label = "Bus", skillKey = "careerSkills-passenger", economyKeys = { "bus" } },
      { id = "taxi", label = "Taxi", skillKey = "careerSkills-passenger", economyKeys = { "taxi" } },
      { id = "facilityWork", label = "Forklift Work", skillKey = "careerSkills-operator", economyKeys = { "facilityWork" } },
      { id = "miningHaul", label = "Skeleton Coast Mining Haul", skillKey = "careerSkills-operator", economyKeys = { "miningHaul" } },
      { id = "repo", label = "Repo", skillKey = "careerSkills-recovery", economyKeys = { "repo" } },
      { id = "offroadRecovery", label = "Off-Road Recovery", skillKey = "careerSkills-recovery", economyKeys = { "offroadRecovery" } },
    },
  },
  {
    id = "racing",
    label = "Racing & Events",
    children = {
      { id = "rally", label = "Rally", skillKey = "careerSkills-dirt", economyKeys = { "rally" } },
      { id = "dirt", label = "Dirt", skillKey = "careerSkills-dirt", economyKeys = { "dirt" } },
      { id = "rallycross", label = "Rallycross", skillKey = "careerSkills-dirt", economyKeys = { "rallycross" } },
      { id = "offroad", label = "Off-Road", skillKey = "careerSkills-offroad", economyKeys = { "offroad" } },
      { id = "crawling", label = "Crawling", skillKey = "careerSkills-offroad", economyKeys = { "crawling", "crawl" } },
      { id = "mudding", label = "Mudding", skillKey = "careerSkills-offroad", economyKeys = { "mudding", "mud" } },
      { id = "trail", label = "Trail (Legacy)", skillKey = "careerSkills-offroad", economyKeys = { "trail" } },
      { id = "drag", label = "Drag", skillKey = "careerSkills-speed", economyKeys = { "drag" } },
      { id = "landspeed", label = "Top Speed", skillKey = "careerSkills-speed", economyKeys = { "landspeed" } },
      { id = "drift", label = "Drift", skillKey = "careerSkills-mayhem", economyKeys = { "drift" } },
      { id = "demo", label = "Demolition Derby", skillKey = "careerSkills-mayhem", economyKeys = { "demo" } },
      { id = "burnout", label = "Burnout", skillKey = "careerSkills-mayhem", economyKeys = { "burnout", "burnoutComp", "freeroam" } },
      { id = "oval", label = "Oval", skillKey = "careerSkills-circuitRacing", economyKeys = { "oval" } },
      { id = "roadracing", label = "Road Racing", skillKey = "careerSkills-circuitRacing", economyKeys = { "roadracing", "apexracing" } },
    },
  },
}

local profileData = {
  umbrellas = {},
  expanded = {},
}

local keyToUmbrellaId = {}
local manifestEconomyKeys = {}
local initialized = false

local function normalizeTypeName(typeName)
  if type(typeName) ~= "string" or typeName == "" then
    return typeName
  end
  local alias = TYPE_ALIASES[typeName:lower()]
  return alias or typeName
end

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

local function getGlobalRewardMultiplier()
  if career_modules_difficultyMode and career_modules_difficultyMode.getRewardMultiplier then
    local value = career_modules_difficultyMode.getRewardMultiplier()
    if type(value) == "number" and value > 0 then
      return value
    end
  end
  return 1.0
end

local function buildManifestIndexes()
  keyToUmbrellaId = {}
  manifestEconomyKeys = {}

  for _, section in ipairs(ECONOMY_SECTIONS) do
    for _, child in ipairs(section.children or {}) do
      for _, economyKey in ipairs(child.economyKeys or {}) do
        keyToUmbrellaId[economyKey] = child.id
        manifestEconomyKeys[economyKey] = true
        local normalized = normalizeTypeName(economyKey)
        if normalized and normalized ~= economyKey then
          keyToUmbrellaId[normalized] = child.id
          manifestEconomyKeys[normalized] = true
        end
      end
    end
  end
  initialized = true
end

local function getRelativeForType(typeName)
  if not initialized then
    buildManifestIndexes()
  end

  local expandedValue = profileData.expanded and profileData.expanded[typeName]
  if type(expandedValue) == "number" then
    return clampRelative(expandedValue)
  end

  local umbrellaId = keyToUmbrellaId[typeName]
  if umbrellaId and profileData.umbrellas and type(profileData.umbrellas[umbrellaId]) == "number" then
    return clampRelative(profileData.umbrellas[umbrellaId])
  end

  return DEFAULT_RELATIVE
end

local function sanitizeProfileTable(raw)
  local sanitized = { umbrellas = {}, expanded = {} }
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

  if type(raw.expanded) == "table" then
    for economyKey, value in pairs(raw.expanded) do
      if type(economyKey) == "string" and type(value) == "number" then
        local clamped = clampRelative(value)
        if math.abs(clamped - DEFAULT_RELATIVE) > 0.001 then
          sanitized.expanded[economyKey] = clamped
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
    expanded = deepcopy(profileData.expanded or {}),
    lastModified = os.time(),
  }
  career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), payload, true)
end

local function consumePendingProfile()
  if not career_career then
    return nil
  end

  local pending = career_career.pendingSandboxEconomyProfile
  career_career.pendingSandboxEconomyProfile = nil
  M.pendingSandboxEconomyProfile = nil

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
    profileData = { umbrellas = {}, expanded = {} }
    return
  end

  local loaded = jsonReadFile(getSaveFilePath(savePath))
  profileData = sanitizeProfileTable(loaded)
end

local function rebuild()
  if isChallengeActive() then
    return false
  end
  if not career_economyAdjuster or not career_economyAdjuster.getAvailableTypes then
    return false
  end

  if not initialized then
    buildManifestIndexes()
  end

  local globalMultiplier = getGlobalRewardMultiplier()
  local availableTypes = career_economyAdjuster.getAvailableTypes() or {}
  if #availableTypes == 0 then
    return false
  end

  local finals = {}
  local unmapped = {}

  for _, typeName in ipairs(availableTypes) do
    local relative = getRelativeForType(typeName)
    finals[typeName] = globalMultiplier * relative

    if not manifestEconomyKeys[typeName] and not keyToUmbrellaId[typeName] then
      table.insert(unmapped, typeName)
    end
  end

  if #unmapped > 0 then
    print(string.format(
      "Economy Adjuster Policy: %d unmapped type(s): %s",
      #unmapped,
      table.concat(unmapped, ", ")
    ))
  end

  if career_economyAdjuster.setAllTypeMultipliers then
    career_economyAdjuster.setAllTypeMultipliers(finals)
    return true
  end
  return false
end

local function setProfileFromUI(rawProfile, skipSave)
  profileData = sanitizeProfileTable(rawProfile)
  if not skipSave then
    saveProfileData()
  end
  return rebuild()
end

local function getManifestForUI()
  if not initialized then
    buildManifestIndexes()
  end
  return deepcopy(ECONOMY_SECTIONS)
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
    profileData = { umbrellas = {}, expanded = {} }
    return false
  end
  loadProfileData(newSave == true)
  return rebuild()
end

local function onSaveCurrentProfile(currentSavePath)
  saveProfileData(currentSavePath)
end

M.rebuild = rebuild
M.getManifestForUI = getManifestForUI
M.getProfileForUI = getProfileForUI
M.setProfileFromUI = setProfileFromUI
M.sanitizeProfileTable = sanitizeProfileTable
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
