-- Racing team manager auto-assign (skill + racingTeamManager.json); see businessSkillTree.
local M = {}

local UPDATE_INTERVAL = 5
local ASSIGN_RETRY_WALL_SEC = 30
local DEFAULT_ASSIGN_INTERVAL_SEC = 1800

local ASSIGN_INTERVAL_OPTIONS = {
  { sec = 600, label = "10 minutes" },
  { sec = 1200, label = "20 minutes" },
  { sec = 1800, label = "30 minutes" },
  { sec = 2700, label = "45 minutes" },
  { sec = 3600, label = "60 minutes" },
}

local accumulator = 0
local timersByBusiness = {}

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

local function getRacingTeam()
  return rawget(_G, "career_modules_business_racingTeam")
end

local function isAllowedAssignIntervalSec(sec)
  sec = math.floor(tonumber(sec) or 0)
  for _, opt in ipairs(ASSIGN_INTERVAL_OPTIONS) do
    if opt.sec == sec then
      return true, sec
    end
  end
  return false
end

local function getManagerTimerPath(businessId, currentSavePath)
  if not currentSavePath or not businessId then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. tostring(businessId) .. "/racingTeamManager.json"
end

local function getManagerSkillLevel(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return 0
  end
  local st = career_modules_business_businessSkillTree
  if not st or not st.getNodeProgress then
    return 0
  end
  return math.max(0, math.floor(tonumber(st.getNodeProgress(businessId, "team-operations", "manager")) or 0))
end

local function hasManagerSkill(businessId)
  return getManagerSkillLevel(businessId) > 0
end

local function loadManagerTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { elapsed = 0, autoAssignEnabled = false, assignIntervalSec = DEFAULT_ASSIGN_INTERVAL_SEC, nextAssignWallEpoch = nil }
  end
  if timersByBusiness[businessId] then
    return timersByBusiness[businessId]
  end
  local _, savePath = career_saveSystem and career_saveSystem.getCurrentProfile and career_saveSystem.getCurrentProfile()
  local path = getManagerTimerPath(businessId, savePath)
  local data = path and jsonReadFile(path) or {}
  local elapsed = math.max(0, tonumber(data.elapsed) or 0)
  local fileExisted = path and FS and FS:fileExists(path) == true
  local autoAssignEnabled
  if data.autoAssignEnabled ~= nil then
    autoAssignEnabled = data.autoAssignEnabled == true
  elseif fileExisted then
    autoAssignEnabled = true
  else
    autoAssignEnabled = false
  end
  local assignIntervalSec = DEFAULT_ASSIGN_INTERVAL_SEC
  local okInterval, normalized = isAllowedAssignIntervalSec(data.assignIntervalSec)
  if okInterval then
    assignIntervalSec = normalized
  end
  local nextAssignWallEpoch = tonumber(data.nextAssignWallEpoch)
  if not nextAssignWallEpoch and autoAssignEnabled then
    nextAssignWallEpoch = os.time() + math.max(0, assignIntervalSec - elapsed)
  end
  timersByBusiness[businessId] = {
    elapsed = elapsed,
    autoAssignEnabled = autoAssignEnabled,
    assignIntervalSec = assignIntervalSec,
    nextAssignWallEpoch = nextAssignWallEpoch,
  }
  return timersByBusiness[businessId]
end

local function writeManagerTimerFile(path, payload)
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    career_saveSystem.jsonWriteFileSafe(path, payload, true)
    return
  end
  jsonWriteFile(path, payload, true)
end

local function saveManagerTimer(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not timersByBusiness[businessId] or not currentSavePath then
    return
  end
  local path = getManagerTimerPath(businessId, currentSavePath)
  if not path then
    return
  end
  local dirPath = string.match(path, "^(.*)/[^/]+$")
  if dirPath and FS and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local st = timersByBusiness[businessId]
  writeManagerTimerFile(path, {
    elapsed = st.elapsed or 0,
    autoAssignEnabled = st.autoAssignEnabled == true,
    assignIntervalSec = st.assignIntervalSec or DEFAULT_ASSIGN_INTERVAL_SEC,
    nextAssignWallEpoch = st.nextAssignWallEpoch,
  })
end

local function persistManagerTimer(businessId, triggerCareerSave)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  local st = timersByBusiness[businessId] or loadManagerTimer(businessId)
  if not st then
    return false
  end
  timersByBusiness[businessId] = st
  if not career_saveSystem or not career_saveSystem.getCurrentProfile then
    return false
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then
    return false
  end
  saveManagerTimer(businessId, savePath)
  if triggerCareerSave and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

local function getManagerAssignmentInterval(businessId)
  businessId = normalizeBusinessId(businessId)
  if getManagerSkillLevel(businessId) < 2 then
    return DEFAULT_ASSIGN_INTERVAL_SEC
  end
  local st = loadManagerTimer(businessId)
  local ok, sec = isAllowedAssignIntervalSec(st.assignIntervalSec)
  if ok then
    return sec
  end
  return DEFAULT_ASSIGN_INTERVAL_SEC
end

local function scheduleNextAssignWall(businessId, delaySec)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local st = loadManagerTimer(businessId)
  st.nextAssignWallEpoch = os.time() + math.max(1, math.floor(tonumber(delaySec) or 1))
  timersByBusiness[businessId] = st
end

local function ensureNextAssignWallEpoch(businessId)
  businessId = normalizeBusinessId(businessId)
  local st = loadManagerTimer(businessId)
  local due = tonumber(st.nextAssignWallEpoch)
  if due and due > 0 then
    return due
  end
  local interval = getManagerAssignmentInterval(businessId)
  local elapsed = tonumber(st.elapsed) or 0
  st.nextAssignWallEpoch = os.time() + math.max(0, math.floor(interval - elapsed))
  timersByBusiness[businessId] = st
  return st.nextAssignWallEpoch
end

local function triggerManagerSettingsUpdated(businessId, extra)
  if not guihooks or not guihooks.trigger then
    return
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local payload = {
    businessId = tostring(businessId),
    autoAssignEnabled = M.getManagerAutoAssignEnabled(businessId),
    assignIntervalSec = M.getManagerAssignIntervalSec(businessId),
    assignIntervalRemainingSec = M.getManagerAssignIntervalRemainingSec(businessId),
    nextAssignWallEpoch = M.getManagerNextAssignWallEpoch(businessId),
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  guihooks.trigger("racingTeamManagerSettingsUpdated", payload)
end

function M.getAssignIntervalOptionsForUI()
  local out = {}
  for _, opt in ipairs(ASSIGN_INTERVAL_OPTIONS) do
    table.insert(out, { sec = opt.sec, label = opt.label })
  end
  return out
end

function M.getManagerAssignmentInterval(businessId)
  return getManagerAssignmentInterval(businessId)
end

function M.getManagerAssignIntervalSec(businessId)
  return M.getManagerAssignmentInterval(businessId)
end

function M.getManagerNextAssignWallEpoch(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) or not M.getManagerAutoAssignEnabled(businessId) then
    return nil
  end
  return ensureNextAssignWallEpoch(businessId)
end

function M.getManagerAssignIntervalRemainingSec(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) then
    return nil
  end
  if not M.getManagerAutoAssignEnabled(businessId) then
    return nil
  end
  local due = ensureNextAssignWallEpoch(businessId)
  return math.max(0, math.floor(due - os.time() + 0.5))
end

function M.setManagerAssignIntervalSec(businessId, intervalSec)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  if getManagerSkillLevel(businessId) < 2 then
    return false
  end
  local ok, normalized = isAllowedAssignIntervalSec(intervalSec)
  if not ok then
    return false
  end
  local st = loadManagerTimer(businessId)
  st.assignIntervalSec = normalized
  if st.autoAssignEnabled then
    scheduleNextAssignWall(businessId, normalized)
  end
  timersByBusiness[businessId] = st
  persistManagerTimer(businessId, true)
  triggerManagerSettingsUpdated(businessId)
  return true, normalized
end

function M.getManagerAutoAssignEnabled(businessId)
  local st = loadManagerTimer(normalizeBusinessId(businessId))
  return st and st.autoAssignEnabled == true
end

function M.setManagerAutoAssignEnabled(businessId, enabled)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  if not hasManagerSkill(businessId) then
    return false
  end
  local st = loadManagerTimer(businessId)
  st.autoAssignEnabled = enabled == true
  if st.autoAssignEnabled then
    scheduleNextAssignWall(businessId, getManagerAssignmentInterval(businessId))
  else
    st.nextAssignWallEpoch = nil
  end
  timersByBusiness[businessId] = st
  persistManagerTimer(businessId, true)
  triggerManagerSettingsUpdated(businessId)
  return true, st.autoAssignEnabled
end

local function driverEligibleForAutoRace(businessId, tech)
  if not tech or tech.fired then
    return false
  end
  if tech.jobId or tech.pendingRaceOffer then
    return false
  end
  if (tech.currentAction or "idle") ~= "idle" then
    return false
  end
  if not tech.fleetVehicleId then
    return false
  end
  local rt = getRacingTeam()
  if rt and rt.getRacingTeamDriverPostRaceCooldownRemainingSec then
    if rt.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) > 0 then
      return false
    end
  end
  return true
end

local function offerMatchesDriverFleet(businessId, rt, tech, offer, requireBracketMatch)
  if not requireBracketMatch then
    return true
  end
  if rt.fleetVehicleEligibleForOffer and rt.fleetVehicleOverpoweredForOffer then
    if not rt.fleetVehicleEligibleForOffer(businessId, tech.fleetVehicleId, offer) then
      return false
    end
    if rt.fleetVehicleOverpoweredForOffer(businessId, tech.fleetVehicleId, offer) then
      return false
    end
    return true
  end
  if rt.sanctionedOfferMatchesFleetVehicle then
    return rt.sanctionedOfferMatchesFleetVehicle(businessId, tech.fleetVehicleId, offer) == true
  end
  return false
end

local function tryManagerAssignOnce(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  if not M.getManagerAutoAssignEnabled(businessId) then
    return false
  end
  local rt = getRacingTeam()
  if not rt or not rt.ensureSanctionedRaceOffersBoard then
    return false
  end
  if not rt.isCurrentLeagueAtLeast or not rt.isCurrentLeagueAtLeast(businessId, 2) then
    return false
  end

  local mgr = career_modules_business_businessManager
  local obj = mgr and mgr.getBusinessObject and mgr.getBusinessObject("racingTeam")
  if not obj or not obj.getTechsForBusiness then
    return false
  end

  local board = rt.ensureSanctionedRaceOffersBoard(businessId)
  local offers = board and board.offers
  if type(offers) ~= "table" or #offers == 0 then
    return false
  end

  local techs = obj.getTechsForBusiness(businessId) or {}
  local requireDriverBracketMatch = getManagerSkillLevel(businessId) >= 2

  for _, tech in ipairs(techs) do
    if driverEligibleForAutoRace(businessId, tech) then
      for _, offer in ipairs(offers) do
        if type(offer) == "table" and offer.id ~= nil then
          if offerMatchesDriverFleet(businessId, rt, tech, offer, requireDriverBracketMatch) then
            if rt.acceptRacingTeamRaceOffer(businessId, offer.id, tech.id) == true then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

local function processManagerAssignDue(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) or not M.getManagerAutoAssignEnabled(businessId) then
    return
  end
  local due = ensureNextAssignWallEpoch(businessId)
  if os.time() < due then
    return
  end
  local interval = getManagerAssignmentInterval(businessId)
  local assigned = tryManagerAssignOnce(businessId)
  if assigned then
    scheduleNextAssignWall(businessId, interval)
  else
    scheduleNextAssignWall(businessId, ASSIGN_RETRY_WALL_SEC)
  end
  if career_saveSystem and career_saveSystem.getCurrentProfile then
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      saveManagerTimer(businessId, savePath)
    end
  end
  triggerManagerSettingsUpdated(businessId, { assignSucceeded = assigned })
  if assigned then
    local rtMod = getRacingTeam()
    if rtMod and rtMod.tickScheduledRaceReadyToasts then
      pcall(rtMod.tickScheduledRaceReadyToasts)
    end
  end
end

function M.tickAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return
  end
  accumulator = accumulator + dtSim
  if accumulator < UPDATE_INTERVAL then
    return
  end
  accumulator = 0

  local mgr = career_modules_business_businessManager
  if not mgr or not mgr.getPurchasedBusinesses then
    return
  end
  local purchased = mgr.getPurchasedBusinesses("racingTeam")
  if type(purchased) ~= "table" then
    return
  end

  for bid, owned in pairs(purchased) do
    if owned and hasManagerSkill(bid) then
      processManagerAssignDue(normalizeBusinessId(bid))
    end
  end
end

function M.processAssignDueNow(businessId)
  processManagerAssignDue(normalizeBusinessId(businessId))
end

function M.devSkipAssignWait(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) then
    return false
  end
  local st = loadManagerTimer(businessId)
  st.nextAssignWallEpoch = os.time()
  timersByBusiness[businessId] = st
  if career_saveSystem and career_saveSystem.getCurrentProfile then
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      saveManagerTimer(businessId, savePath)
    end
  end
  processManagerAssignDue(businessId)
  return true
end

function M.onCareerActivated()
  accumulator = 0
  timersByBusiness = {}
end

function M.onSaveCurrentProfile(currentSavePath)
  if not currentSavePath then
    return
  end
  local mgr = career_modules_business_businessManager
  if not mgr or not mgr.getPurchasedBusinesses then
    return
  end
  local purchased = mgr.getPurchasedBusinesses("racingTeam")
  if type(purchased) ~= "table" then
    return
  end
  for bid, owned in pairs(purchased) do
    if owned and hasManagerSkill(bid) then
      local id = normalizeBusinessId(bid)
      loadManagerTimer(id)
      saveManagerTimer(id, currentSavePath)
    end
  end
end

return M
