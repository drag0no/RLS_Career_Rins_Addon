local M = {}

M.dependencies = {"career_career"}

-- What's New splash.
--
-- All player-facing content lives next to its photos in
--   /ui/modules/whatsnew/<folder>/slides.json
-- To ship a new splash: create a new folder with slides.json + images, then
-- update `id` and `folder` below. Changing `id` makes the splash appear once
-- again for everyone (each id is acknowledged separately in the UI's storage),
-- so a hotfix can keep the old id and stay silent.
local currentCycle = {
  enabled = true,
  id = "2.7.1_hotifx",
  folder = "2.7.1_hotifx",
}

local CONTENT_ROOT = "/ui/modules/whatsnew/"

local cachedContent = nil
local cachedFolder = nil
local pendingShow = false

local function loadContent(forceReload)
  local folder = currentCycle.folder or currentCycle.id
  if cachedContent and cachedFolder == folder and not forceReload then
    return cachedContent
  end
  local base = CONTENT_ROOT .. folder
  local data = jsonReadFile(base .. "/slides.json")
  if type(data) ~= "table" or type(data.slides) ~= "table" or #data.slides == 0 then
    log("E", "betaWelcome", "What's New content missing or empty: " .. base .. "/slides.json")
    return nil
  end
  data.imageBase = base .. "/"
  cachedContent = data
  cachedFolder = folder
  return data
end

local function getSummary(force)
  local content = loadContent(force == true)
  local summary = content and deepcopy(content) or { slides = {} }
  summary.enabled = currentCycle.enabled and content ~= nil
  summary.id = currentCycle.id
  summary.label = summary.label or ("v" .. tostring(currentCycle.id))
  summary.force = force == true
  return summary
end

local function isCareerUiReady()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return false
  end
  if core_gamestate and core_gamestate.getLoadingStatus then
    if core_gamestate.getLoadingStatus("careerLoading") then return false end
    if core_gamestate.getLoadingStatus("careerActivate") then return false end
  end
  return true
end

local function requestSplash(force)
  if not currentCycle.enabled then return nil end
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return nil
  end

  local ready = force == true or isCareerUiReady()
  pendingShow = not ready
  local summary = getSummary(force)
  summary.interactive = ready
  if guihooks and guihooks.trigger then
    guihooks.trigger("RlsBetaCycleSplashShow", summary)
  end
  return summary
end

-- Dev helper: re-read slides.json and show the splash regardless of career
-- state or the "don't show again" flag. Run from the console:
--   career_modules_betaWelcome.preview()
local function preview()
  local summary = getSummary(true)
  summary.interactive = true
  summary.preview = true
  if guihooks and guihooks.trigger then
    guihooks.trigger("RlsBetaCycleSplashShow", summary)
  end
  return summary
end

local function onCareerActivated()
  requestSplash(false)
end

local function onWorldReadyState(state)
  if state ~= 2 then return end
  if pendingShow then
    requestSplash(false)
  end
end

M.getSummary = getSummary
M.isCareerUiReady = isCareerUiReady
M.requestSplash = requestSplash
M.preview = preview
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = onWorldReadyState

return M
