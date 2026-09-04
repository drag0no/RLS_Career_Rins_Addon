-- Stock gameplay_statistic keeps career metrics in a local `fileDataCareer`.
-- onCareerActive(false) clears it; onCareerActive(true) can early-return when the
-- profile isn't ready yet, leaving nil. The next onSaveCurrentProfile then writes
-- nil → saveFailed → autosave slot stamped corrupted.
--
-- Guard: if the table is missing, ask stock to reload it (onCareerActive(true)).
-- Do not use debug.setupvalue — BeamNG's Lua sandbox fatals on that.

local M = {}

local logTag = "statisticSaveGuard"
local registryKey = "__rlsStatisticSaveGuard"
local ownerToken = {}
local origOnSaveCurrentProfile
local origOnCareerActive
local patched = false
local recovering = false

local function findUpvalue(fn, name)
  if type(fn) ~= "function" then return nil end
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then return nil end
    if n == name then return i, v end
    i = i + 1
  end
end

-- Older versions of this extension kept their original callbacks only in Lua
-- upvalues. If one of those wrappers survived an extension reload, walk through
-- the wrapper chain until we reach the genuine stock callback.
local function unwrapLegacy(fn, originalUpvalueName)
  local current = fn
  local seen = {}
  for _ = 1, 16 do
    if type(current) ~= "function" or seen[current] then break end
    seen[current] = true
    local _, inner = findUpvalue(current, originalUpvalueName)
    if type(inner) ~= "function" or inner == current then break end
    current = inner
  end
  return current
end

local function getOrCreateRegistry()
  local registry = rawget(gameplay_statistic, registryKey)
  if type(registry) == "table"
    and type(registry.originalSave) == "function"
    and type(registry.originalCareer) == "function" then
    return registry
  end

  registry = {
    version = 1,
    originalSave = unwrapLegacy(gameplay_statistic.onSaveCurrentProfile, "origOnSaveCurrentProfile"),
    originalCareer = unwrapLegacy(gameplay_statistic.onCareerActive, "origOnCareerActive"),
  }
  gameplay_statistic[registryKey] = registry
  return registry
end

local function inspectFileDataCareer()
  local saveFn = origOnSaveCurrentProfile or (gameplay_statistic and gameplay_statistic.onSaveCurrentProfile)
  if type(saveFn) ~= "function" then
    return nil, "noSaveFn"
  end
  local idx, data = findUpvalue(saveFn, "fileDataCareer")
  if not idx then
    return nil, "noUpvalue"
  end
  return data, "ok"
end

local function loadCareerStatsFromDisk()
  local slot, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then
    return { version = 1, entries = {} }, slot, savePath, "noSavePath"
  end
  local loaded = jsonReadFile(savePath .. "/career/gameplay_stat.json")
  if not loaded or type(loaded.entries) ~= "table" or not loaded.version then
    return { version = 1, entries = {} }, slot, savePath, "missingOrInvalidFile"
  end
  return loaded, slot, savePath, "loadedFromDisk"
end

local function ensureFileDataCareer(reason)
  local data, inspectHow = inspectFileDataCareer()
  if type(data) == "table" then
    return data
  end

  local _, slot, savePath, how = loadCareerStatsFromDisk()
  local careerActive = career_career and career_career.isActive and career_career.isActive()
  log("E", logTag, string.format(
    "fileDataCareer was %s during %s (inspect=%s) — recovering via stock onCareerActive(true); disk=%s (careerActive=%s profile=%s path=%s)",
    type(data), tostring(reason), tostring(inspectHow), tostring(how),
    tostring(careerActive), tostring(slot), tostring(savePath)))
  log("E", logTag, debug.traceback())

  if recovering then
    return inspectFileDataCareer()
  end
  if type(origOnCareerActive) ~= "function" then
    return data
  end

  recovering = true
  origOnCareerActive(true)
  recovering = false

  data = inspectFileDataCareer()
  if type(data) ~= "table" then
    log("E", logTag, "stock onCareerActive(true) did not restore fileDataCareer")
  end
  return data
end

local function onSaveCurrentProfile(currentSavePath, ...)
  local data = ensureFileDataCareer("onSaveCurrentProfile")
  if type(data) ~= "table" then
    -- Stock would jsonWriteFile(nil) and stamp the slot corrupted. Write a
    -- recovered copy ourselves; jsonWriteFileSafe also refuses non-tables.
    local recovered = loadCareerStatsFromDisk()
    local careerSaveFilePath = currentSavePath .. "/career/gameplay_stat.json"
    if not career_saveSystem.jsonWriteFileSafe(careerSaveFilePath, recovered) then
      log("E", logTag, "failed to write recovered career json")
    end
    return
  end
  return origOnSaveCurrentProfile(currentSavePath, ...)
end

local function onCareerActive(active, ...)
  local result = origOnCareerActive(active, ...)
  if active and not recovering then
    -- Stock early-returns when getCurrentProfile() has no slot, leaving fileDataCareer nil.
    ensureFileDataCareer("onCareerActive(true)")
  end
  return result
end

local function patch()
  if patched then return end
  if not gameplay_statistic then return end
  if type(gameplay_statistic.onSaveCurrentProfile) ~= "function" then return end

  local registry = getOrCreateRegistry()
  origOnSaveCurrentProfile = registry.originalSave
  origOnCareerActive = registry.originalCareer
  if type(origOnSaveCurrentProfile) ~= "function" then return end

  registry.owner = ownerToken
  registry.saveWrapper = onSaveCurrentProfile
  registry.careerWrapper = onCareerActive
  gameplay_statistic.onSaveCurrentProfile = onSaveCurrentProfile
  if type(origOnCareerActive) == "function" then
    gameplay_statistic.onCareerActive = onCareerActive
  end
  patched = true
  -- Hook dispatch caches function pointers; invalidate so our wraps are used.
  if extensions.hookUpdate then
    extensions.hookUpdate("onSaveCurrentProfile")
    extensions.hookUpdate("onCareerActive")
  end
  log("I", logTag, "patched gameplay_statistic save/career hooks")
end

local function unpatch()
  if not gameplay_statistic then return end
  local registry = rawget(gameplay_statistic, registryKey)
  if type(registry) ~= "table" or registry.owner ~= ownerToken then return end

  if gameplay_statistic.onSaveCurrentProfile == onSaveCurrentProfile then
    gameplay_statistic.onSaveCurrentProfile = registry.originalSave
  end
  if gameplay_statistic.onCareerActive == onCareerActive then
    gameplay_statistic.onCareerActive = registry.originalCareer
  end
  gameplay_statistic[registryKey] = nil
  patched = false
  if extensions.hookUpdate then
    extensions.hookUpdate("onSaveCurrentProfile")
    extensions.hookUpdate("onCareerActive")
  end
  log("I", logTag, "restored gameplay_statistic save/career hooks")
end

local function ensureReady(reason)
  patch()
  return ensureFileDataCareer(reason or "ensureReady")
end

local function onExtensionLoaded()
  patch()
end

local function onCareerActivated()
  ensureReady("onCareerActivated")
end

M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onExtensionUnloaded = unpatch
M.ensureReady = ensureReady

return M
