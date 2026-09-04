local M = {}
M.dependencies = {"career_branches", "career_saveSystem"}

local LEGACY_BRANCH_PATH_ALIASES = {
  ["careerSkills-police"] = "careerSkills-civilService-police",
}

local branchMigration = {
  version = 1,
  markerFile = "career/civilServiceBranchMigration.json",
  branchUnlocksFile = "career/branchUnlocks.json",
  milestonesFile = "career/milestones/general.json",
}

local function applyBranchPathAliases()
  if not career_branches or not career_branches.oldAttributeNamesToNewNames then
    return
  end
  for oldPath, newPath in pairs(LEGACY_BRANCH_PATH_ALIASES) do
    career_branches.oldAttributeNamesToNewNames[oldPath] = newPath
  end
end

local function migrateKeyedTable(jsonData, keyMap)
  if type(jsonData) ~= "table" then
    return false
  end
  local changed = false
  for oldKey, newKey in pairs(keyMap) do
    if jsonData[oldKey] ~= nil then
      jsonData[newKey] = jsonData[newKey] or {}
      for field, value in pairs(jsonData[oldKey]) do
        if jsonData[newKey][field] == nil then
          jsonData[newKey][field] = value
        end
      end
      jsonData[oldKey] = nil
      changed = true
    end
  end
  return changed
end

local function runCivilServiceBranchMigration(savePath)
  if not savePath or savePath == "" then
    return
  end

  local markerPath = savePath .. "/" .. branchMigration.markerFile
  local markerData = jsonReadFile(markerPath) or {}
  if (markerData.version or 0) >= branchMigration.version then
    return
  end

  local branchKeyMap = {}
  local milestoneKeyMap = {}
  for oldPath, newPath in pairs(LEGACY_BRANCH_PATH_ALIASES) do
    branchKeyMap[oldPath] = newPath
    milestoneKeyMap["branch_" .. oldPath] = "branch_" .. newPath
  end

  local changed = false
  local writesSucceeded = true
  local branchUnlocksPath = savePath .. "/" .. branchMigration.branchUnlocksFile
  local branchUnlocks = jsonReadFile(branchUnlocksPath)
  if branchUnlocks and migrateKeyedTable(branchUnlocks, branchKeyMap) then
    if not career_saveSystem.jsonWriteFileSafe(branchUnlocksPath, branchUnlocks, true) then
      writesSucceeded = false
    else
      changed = true
    end
  end

  local milestonesPath = savePath .. "/" .. branchMigration.milestonesFile
  local milestonesData = jsonReadFile(milestonesPath)
  if milestonesData and milestonesData.general and migrateKeyedTable(milestonesData.general, milestoneKeyMap) then
    if not career_saveSystem.jsonWriteFileSafe(milestonesPath, milestonesData, true) then
      writesSucceeded = false
    else
      changed = true
    end
  end

  if writesSucceeded then
    career_saveSystem.jsonWriteFileSafe(markerPath, {
      version = branchMigration.version,
      migratedAt = os.time(),
      changed = changed,
    }, true)
  end
end

local function onExtensionLoaded()
  applyBranchPathAliases()
end

local function onCareerModulesActivated()
  applyBranchPathAliases()
  local _, savePath = career_saveSystem.getCurrentProfile()
  runCivilServiceBranchMigration(savePath)
end

M.onExtensionLoaded = onExtensionLoaded
M.onCareerModulesActivated = onCareerModulesActivated

return M
