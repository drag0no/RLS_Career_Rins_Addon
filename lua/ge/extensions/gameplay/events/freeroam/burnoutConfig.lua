local M = {}

local TRIGGER_PREFIX = "rls_burnoutTestZone_"
local CONFIG_FILENAME = "burnout.config.json"
local SITES_FILENAME = "burnout.sites.json"
local DEFAULT_SCORE_GOAL = 6000
local DEFAULT_REWARD = 200
local DEFAULT_TIME = 60

local cache = nil

local function normalizeEvent(event)
  if type(event) ~= "table" then
    return nil
  end

  local zoneId = event.zoneId
  if (not zoneId or zoneId == "") and type(event.triggerName) == "string" then
    zoneId = event.triggerName:match("^rls_burnoutTestZone_(.+)$") or event.triggerName:match("^rls_burnoutZone_(.+)$")
  end
  if not zoneId or zoneId == "" then
    return nil
  end

  local zoneName = event.zoneName or event.siteZoneName
  local triggerName = event.triggerName
  if type(triggerName) ~= "string" or triggerName == "" then
    triggerName = not zoneName and (TRIGGER_PREFIX .. zoneId) or nil
  end
  local scoreGoal = event.driftGoal or event.scoreGoal or DEFAULT_SCORE_GOAL
  return {
    eventId = event.eventId or ("burnout_" .. zoneId),
    zoneId = zoneId,
    zoneName = zoneName,
    label = event.label or event.name or ("Burnout " .. zoneId),
    types = event.types or {"burnout", "freeroam"},
    triggerName = triggerName,
    thumbnail = event.thumbnail,
    driftGoal = scoreGoal,
    scoreGoal = event.scoreGoal or event.driftGoal or scoreGoal,
    driftTargetTime = event.driftTargetTime or DEFAULT_TIME,
    bestTime = event.bestTime or DEFAULT_TIME,
    reward = event.reward or DEFAULT_REWARD,
  }
end

local function loadLevelData(level)
  if not level or level == "" then
    return {level = level, events = {}, zonesByName = {}, sitesFile = SITES_FILENAME, sites = nil}
  end
  if cache and cache.level == level then
    return cache
  end

  local config = jsonReadFile("levels/" .. level .. "/" .. CONFIG_FILENAME)
  local sitesFile = type(config) == "table" and config.sitesFile or nil
  if type(sitesFile) ~= "string" or sitesFile == "" then
    sitesFile = SITES_FILENAME
  end
  local sites = jsonReadFile("levels/" .. level .. "/" .. sitesFile)

  -- New maps keep event metadata in burnout.config.json and Sites geometry in
  -- burnout.sites.json. Older maps embedded the event list in burnout.sites.json;
  -- retain that layout so their BeamNGTrigger integrations continue to work.
  local source = type(config) == "table" and (config.events or config.burnouts) or nil
  if type(source) ~= "table" and type(sites) == "table" then
    source = sites.events or sites.burnouts
  end
  source = type(source) == "table" and source or {}
  local events = {}
  for _, event in ipairs(source) do
    local normalized = normalizeEvent(event)
    if normalized then
      table.insert(events, normalized)
    end
  end

  local zonesByName = {}
  for _, zone in ipairs(type(sites) == "table" and sites.zones or {}) do
    if type(zone) == "table" and type(zone.name) == "string" and zone.name ~= "" then
      zonesByName[zone.name] = zone
    end
  end

  cache = {
    level = level,
    events = events,
    zonesByName = zonesByName,
    sitesFile = sitesFile,
    sites = sites,
  }
  return cache
end

M.TRIGGER_PREFIX = TRIGGER_PREFIX
M.normalizeEvent = normalizeEvent
M.loadLevelData = loadLevelData

return M
