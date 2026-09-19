local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'freeroam_facilities', 'career_modules_business_businessTabRegistry', 'career_modules_business_businessHelpers', 'career_modules_business_businessInventory', 'career_modules_business_businessManager', 'career_modules_business_racingTeamRaceFlow', 'gameplay_events_freContracts_state', 'gameplay_events_freContracts_sanctionedRacing', 'gameplay_raceBusinessDriver', 'core_jobsystem'}

local racingTeamFinances = require('ge/extensions/career/modules/business/racingTeamFinances')
local racingTeamManager = require('ge/extensions/career/modules/business/racingTeamManager')
local racingTeamBuildClass = require('ge/extensions/career/modules/business/racingTeamBuildClass')
local racingTeamSponsors = require('ge/extensions/career/modules/business/racingTeamSponsors')
local racingTeamLeagueInvite = require('ge/extensions/career/modules/business/racingTeamLeagueInvite')
local racingTeamRaceOffers = require('ge/extensions/career/modules/business/racingTeamRaceOffers')
local racingTeamFleet = require('ge/extensions/career/modules/business/racingTeamFleet')
local racingTeamGoals = require('ge/extensions/career/modules/business/racingTeamGoals')
local racingTeamRaceSim = require('ge/extensions/career/modules/business/racingTeamRaceSim')
require('ge/extensions/career/modules/business/racingTeamDevLog')

local rtState = require('ge/extensions/career/modules/business/racingTeamRuntimeState')
local getOfferState, syncRacingTeamDriverUnlock


local function proxyPodiumXpFromMoney(m)
  return math.max(0, math.floor((tonumber(m) or 0) * rtState.K.PROXY_PODIUM_XP_OF_MONEY + 1e-9))
end

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function getVehicleDynoStatus(businessId, vehicleId)
  if not businessId or vehicleId == nil then
    return 0
  end
  local idStr = tostring(normalizeBusinessId(businessId))
  local vidStr = tostring(vehicleId)
  if rtState.dynoRequiredByBusiness and rtState.dynoRequiredByBusiness[idStr] and rtState.dynoRequiredByBusiness[idStr][vidStr] == true then
    return -1
  end
  local peaks = rtState.classOptimizationPeakHpByBusiness and rtState.classOptimizationPeakHpByBusiness[idStr]
  if peaks and peaks[vidStr] ~= nil then
    return 1
  end
  return 0
end

local function isOfferBlockedByDyno(businessId, vehicleId, offer)
  if not offer or getVehicleDynoStatus(businessId, vehicleId) ~= -1 then
    return false
  end
  local branch = offer.hpBracketBranch or offer.branch
  return branch ~= nil and branch ~= "stock"
end

local function showDynoRequiredMessageIfBlocked(businessId, vehicleId, offer)
  if isOfferBlockedByDyno(businessId, vehicleId, offer) then
    if ui_message then ui_message("Dyno Certification Required: Vehicle must be dyno-tested to enter sanctioned races.", 6, "Racing Team", "warning") end
    return true
  else
    return false
  end
end

local function rtDevLog(businessId, level, message, source, context)
  local dl = rtState.rtInternal.devLog
  if dl and dl.append then
    dl.append(businessId, level, message, source, context)
  end
end

local function getSkillTreeNodeLevel(businessId, treeId, nodeId)
  if not businessId or not treeId or not nodeId then return 0 end
  local mod = career_modules_business_businessSkillTree
  if not mod or not mod.getNodeProgress then return 0 end
  local ok, lv = pcall(mod.getNodeProgress, normalizeBusinessId(businessId), treeId, nodeId)
  return (ok and math.max(0, math.floor(tonumber(lv) or 0))) or 0
end

local function hasManagerLevel1(businessId)
  return getSkillTreeNodeLevel(businessId, "team-operations", "manager") >= 1
end

local function hasManagerLevel2(businessId)
  return getSkillTreeNodeLevel(businessId, "team-operations", "manager") >= 2
end

local function getRacingTeamGarageSlotsSkillLevel(businessId)
  return getSkillTreeNodeLevel(businessId, "qol", "garageSlots")
end

local function getMaxRaceOffersOnBoard(businessId)
  local n = math.max(1, rtState.K.MAX_RACE_OFFERS_ON_BOARD + getSkillTreeNodeLevel(businessId, "team-operations", "scout-network"))
  return math.min(4, n)
end

local function raceFlowMod()
  -- BeamNG: do not use extensions.get; use _G.
  return rawget(_G, "career_modules_business_racingTeamRaceFlow")
end

local function league2InvitePromoKey(businessId)
  return tostring(normalizeBusinessId(businessId))
end

local function buildOfferFromFactoryConfig(cfg, jobId)
  local name, vehicleYear, vehicleType, vehicleImage =
    career_modules_business_businessHelpers.extractDisplayInfo(cfg)
  local vehicleName = name or cfg.model_key or "Unknown"

  local reward = math.random(8000, 28000)

  local mileageMiles = math.random (20000, 120000)
  return {
    id = jobId,
    jobId = jobId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    reward = reward,
    goal = "Purchase Price",
    status = "new",
    businessType = rtState.businessType,
    vehicleConfig = {
      model_key = cfg.model_key,
      key = cfg.key
    },
    mileage = mileageMiles * 1609.34
  }
end

local function generateVehicleOffer(businessId)
  local configs = rtState.getFactoryConfigs()
  if not configs or #configs == 0 then
    return nil
  end
  local cfg = configs[math.random(#configs)]
  if not cfg or not cfg.model_key or not cfg.key then
    return nil
  end
  local id = tostring(normalizeBusinessId(businessId))
  local nextId = (rtState.offerJobIdCounters[id] or 0) + 1
  rtState.offerJobIdCounters[id] = nextId
  return buildOfferFromFactoryConfig(cfg, nextId)
end

local function getRacingTeamSavePath(businessId, currentSavePath)
  if not currentSavePath or not businessId then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. tostring(businessId) .. "/racingTeam.json"
end

local function bumpOfferJobCounterFromState(businessIdStr, state)
  local maxId = rtState.offerJobIdCounters[businessIdStr] or 0
  local function considerJob(job)
    if job and job.jobId ~= nil then
      local n = tonumber(job.jobId)
      if n and n > maxId then
        maxId = n
      end
    end
  end
  for _, job in ipairs(state.new or {}) do
    considerJob(job)
  end
  for _, job in ipairs(state.active or {}) do
    considerJob(job)
  end
  rtState.offerJobIdCounters[businessIdStr] = maxId
end

local function loadRacingTeamPersistedState(businessId, state)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then
    return
  end
  local bid = normalizeBusinessId(businessId)
  local id = tostring(bid)
  local filePath = getRacingTeamSavePath(bid, savePath)
  if not filePath or not FS or not FS.fileExists then
    return
  end
  if not FS:fileExists(filePath) then
    return
  end
  local data = jsonReadFile(filePath)
  if not data or type(data) ~= "table" then
    return
  end
  state.new = {}
  if data.active and type(data.active) == "table" then
    state.active = data.active
  end
  if data.raceOfferBoard and type(data.raceOfferBoard) == "table" then
    local rb = data.raceOfferBoard
    local rawOffers = rb.offers
    local offers = {}
    if type(rawOffers) == "table" then
      for i, o in ipairs(rawOffers) do
        table.insert(offers, o)
      end
    end
    rtState.raceOfferBoardByBusiness[id] = {
      levelId = type(rb.levelId) == "string" and rb.levelId or "",
      nextRefreshAt = tonumber(rb.nextRefreshAt) or 0,
      offers = offers,
    }
  end
  local savedCounter = tonumber(data.offerJobIdCounter)
  if savedCounter then
    rtState.offerJobIdCounters[id] = math.max(rtState.offerJobIdCounters[id] or 0, savedCounter)
  end
  bumpOfferJobCounterFromState(id, state)
  local proxyFlow = raceFlowMod()
  if proxyFlow and proxyFlow.loadPersistedProxyDriverRaceRequest then
    proxyFlow.loadPersistedProxyDriverRaceRequest(id, data.proxyDriverRaceRequest)
  end
  if data.pendingRematchOffer and type(data.pendingRematchOffer) == "table" then
    rtState.pendingRematchOfferByBusiness[id] = data.pendingRematchOffer
  else
    rtState.pendingRematchOfferByBusiness[id] = nil
  end
  rtState.goalCompletionByBusiness[id] = rtState.goalCompletionByBusiness[id] or {}
  if data.completedGoalIds and type(data.completedGoalIds) == "table" then
    for _, gid in ipairs(data.completedGoalIds) do
      if type(gid) == "string" then
        rtState.goalCompletionByBusiness[id][gid] = true
      end
    end
  end
  if type(data.currentLeague) == "string" and data.currentLeague ~= "" then
    rtState.currentLeagueByBusiness[id] = data.currentLeague
  else
    rtState.currentLeagueByBusiness[id] = "league1"
  end
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local tmg = rtState.tuningMilestoneByGoalByBusiness[id]
  if data.tuningMilestonesCompleted and type(data.tuningMilestonesCompleted) == "table" then
    for _, gid in ipairs(data.tuningMilestonesCompleted) do
      if type(gid) == "string" then
        tmg[gid] = true
      end
    end
  end
  if data.tuningMilestoneAchieved == true and next(tmg) == nil then
    tmg["rt_t1_g3"] = true
  end
  rtState.tuningMilestoneByBusiness[id] = next(tmg) ~= nil
  rtState.homeMechanicBaselinePwByBusiness[id] = tonumber(data.homeMechanicBaselinePw)
  rtState.businessSkillXpByBusiness[id] = math.max(0, math.floor(tonumber(data.businessSkillXp) or 0))
  if data.shortTrackCleanStreak ~= nil then
    rtState.staminaShortTrackStreakByBusiness[id] = math.max(0, math.floor(tonumber(data.shortTrackCleanStreak) or 0))
  end
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] =
    math.max(0, math.floor(tonumber(data.sanctionedOfficialFirstPlaceWins) or 0))
  rtState.classOptimizationPeakHpByBusiness[id] = {}
  if data.classOptimizationPeakHp and type(data.classOptimizationPeakHp) == "table" then
    for k, v in pairs(data.classOptimizationPeakHp) do
      local keyStr = tostring(k)
      if type(v) == "table" then
        local hp = tonumber(v.hp)
        local wkg = tonumber(v.weightKg)
        if wkg and wkg > 0 then
          if hp and hp > 0 then
            rtState.classOptimizationPeakHpByBusiness[id][keyStr] = { hp = hp, weightKg = wkg }
          else
            rtState.classOptimizationPeakHpByBusiness[id][keyStr] = { weightKg = wkg }
          end
        elseif hp and hp > 0 then
          rtState.classOptimizationPeakHpByBusiness[id][keyStr] = hp
        end
      else
        local hp = tonumber(v)
        if hp and hp > 0 then
          rtState.classOptimizationPeakHpByBusiness[id][keyStr] = hp
        end
      end
    end
  end
  rtState.dynoRequiredByBusiness[id] = {}
  if data.dynoRequired and type(data.dynoRequired) == "table" then
    for k, v in pairs(data.dynoRequired) do
      if v == true then
        rtState.dynoRequiredByBusiness[id][tostring(k)] = true
      end
    end
  end
  local l2Offered = tonumber(data.league2InviteOfferedAt) or tonumber(data.wcaraInviteOfferedAt)
  local l2Declined = (data.league2InviteDeclined == true) or (data.wcaraInviteDeclined == true)
  local invTarget = data.league2InviteTargetLeague
  if type(invTarget) ~= "string" or (invTarget ~= "league2" and invTarget ~= "league3" and invTarget ~= "league4") then
    invTarget = nil
  end
  if invTarget == nil and l2Offered then
    invTarget = "league2"
  end
  rtState.league2InviteByBusiness[id] = {
    offeredAt = l2Offered,
    declined = l2Declined,
    targetLeague = invTarget,
  }
  local promoUi = data.league2InvitePromoUi or data.wcaraPromoUiState
  if type(promoUi) == "string" and (promoUi == "splash" or promoUi == "jobs") then
    rtState.league2InvitePromoUiByBusiness[id] = promoUi
  elseif l2Offered then
    rtState.league2InvitePromoUiByBusiness[id] = "splash"
  else
    rtState.league2InvitePromoUiByBusiness[id] = nil
  end
  rtState.purchaseMilestoneSplashShownByBusiness[id] = data.purchaseMilestoneSplashShown == true
  rtState.raceUnlockSplashPendingByBusiness[id] = data.raceUnlockSplashPending == true
  rtState.raceUnlockSplashShownByBusiness[id] = data.raceUnlockSplashShown == true
  rtState.careerFinaleSplashPendingByBusiness[id] = data.careerFinaleSplashPending == true
  rtState.careerFinaleSplashShownByBusiness[id] = data.careerFinaleSplashShown == true
  rtState.vehicleCooldownByBusiness[id] = {}
  if data.vehicleCooldowns and type(data.vehicleCooldowns) == "table" then
    for vidKey, rec in pairs(data.vehicleCooldowns) do
      if type(rec) == "table" then
        local untilSim = tonumber(rec.untilSim)
        local wallEpoch = tonumber(rec.wallEpoch)
        if (untilSim and untilSim > 0) or (wallEpoch and wallEpoch > 0) then
          rtState.vehicleCooldownByBusiness[id][tostring(vidKey)] = {
            untilSim = untilSim,
            wallEpoch = wallEpoch,
          }
        end
      end
    end
  end
  rtState.playerCooldownByBusiness[id] = nil
  if data.playerCooldown and type(data.playerCooldown) == "table" then
    local untilSim = tonumber(data.playerCooldown.untilSim)
    local wallEpoch = tonumber(data.playerCooldown.wallEpoch)
    if (untilSim and untilSim > 0) or (wallEpoch and wallEpoch > 0) then
      rtState.playerCooldownByBusiness[id] = {
        untilSim = untilSim,
        wallEpoch = wallEpoch,
      }
    end
  end
  if data.racingTeamSponsors and type(data.racingTeamSponsors) == "table" then
    rtState.rtInternal.sponsors[id] = {
      available = type(data.racingTeamSponsors.available) == "table" and data.racingTeamSponsors.available or {},
      active = type(data.racingTeamSponsors.active) == "table" and data.racingTeamSponsors.active or {},
      nextOfferAt = tonumber(data.racingTeamSponsors.nextOfferAt) or 0,
    }
  else
    rtState.rtInternal.sponsors[id] = {
      available = {},
      active = {},
      nextOfferAt = 0,
    }
  end
  rtState.allLeaderboardsBaselineByBusiness[id] = rtState.allLeaderboardsBaselineByBusiness[id] or {}
  if data.allLeaderboardsBaselines and type(data.allLeaderboardsBaselines) == "table" then
    for gid, arr in pairs(data.allLeaderboardsBaselines) do
      if type(gid) == "string" and type(arr) == "table" then
        local clean = {}
        for _, row in ipairs(arr) do
          if type(row) == "table" and row.raceType and row.raceLabel then
            table.insert(clean, {
              raceType = row.raceType,
              raceLabel = row.raceLabel,
              baselineSec = tonumber(row.baselineSec),
            })
          end
        end
        rtState.allLeaderboardsBaselineByBusiness[id][gid] = clean
      end
    end
  end
  rtState.completedGoalLeaderboardTimesByBusiness[id] = {}
  if data.completedGoalLeaderboardTimes and type(data.completedGoalLeaderboardTimes) == "table" then
    for gid, snap in pairs(data.completedGoalLeaderboardTimes) do
      if type(gid) == "string" and type(snap) == "table" then
        if snap.kind == "single" then
          rtState.completedGoalLeaderboardTimesByBusiness[id][gid] = {
            kind = "single",
            bestSec = tonumber(snap.bestSec),
          }
        elseif snap.kind == "tracks" and type(snap.tracks) == "table" then
          local rows = {}
          for _, row in ipairs(snap.tracks) do
            if type(row) == "table" and row.raceType and row.raceLabel then
              table.insert(rows, {
                raceType = row.raceType,
                raceLabel = row.raceLabel,
                bestSec = tonumber(row.bestSec),
              })
            end
          end
          rtState.completedGoalLeaderboardTimesByBusiness[id][gid] = { kind = "tracks", tracks = rows }
        end
      end
    end
  end
  if data.autoStartBackgroundRaces ~= nil then
    rtState.autoStartBackgroundRacesByBusiness[id] = data.autoStartBackgroundRaces == true
  else
    rtState.autoStartBackgroundRacesByBusiness[id] = true
  end
  racingTeamRaceSim.loadPersistedState(businessId, data.activeBackgroundRaceSim)
end

local function saveRacingTeamPersistedState(businessId, currentSavePath)
  if not businessId or not currentSavePath then
    return
  end
  local bid = normalizeBusinessId(businessId)
  local id = tostring(bid)
  local state = rtState.offerStateByBusiness[id]
  if not state then
    return
  end
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local filePath = getRacingTeamSavePath(bid, currentSavePath)
  if not filePath then
    return
  end
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local completedList = {}
  local gMap = rtState.goalCompletionByBusiness[id] or {}
  for gid, done in pairs(gMap) do
    if done then
      table.insert(completedList, gid)
    end
  end
  local rb = rtState.raceOfferBoardByBusiness[id]
  local data = {
    completedGoalIds = completedList,
    currentLeague = rtState.currentLeagueByBusiness[id] or "league1",
    tuningMilestoneAchieved = (function()
      local m = rtState.tuningMilestoneByGoalByBusiness[id] or {}
      return m["rt_t1_g3"] == true
    end)(),
    tuningMilestonesCompleted = (function()
      local m = rtState.tuningMilestoneByGoalByBusiness[id] or {}
      local out = {}
      for gid, v in pairs(m) do
        if v and type(gid) == "string" then
          table.insert(out, gid)
        end
      end
      table.sort(out)
      return out
    end)(),
    homeMechanicBaselinePw = rtState.homeMechanicBaselinePwByBusiness[id],
    offerJobIdCounter = rtState.offerJobIdCounters[id] or 0,
    new = state.new or {},
    active = state.active or {},
    raceOfferBoard = rb and {
      levelId = rb.levelId or "",
      nextRefreshAt = tonumber(rb.nextRefreshAt) or 0,
      offers = rb.offers or {},
    } or nil,
    proxyDriverRaceRequest = (function()
      local proxyFlow = raceFlowMod()
      if proxyFlow and proxyFlow.getPersistedProxyDriverRaceRequestForSave then
        return proxyFlow.getPersistedProxyDriverRaceRequestForSave(id)
      end
      return nil
    end)(),
    pendingRematchOffer = rtState.pendingRematchOfferByBusiness[id],
    businessSkillXp = math.max(0, math.floor(tonumber(rtState.businessSkillXpByBusiness[id]) or 0)),
    shortTrackCleanStreak = rtState.staminaShortTrackStreakByBusiness[id] or 0,
    sanctionedOfficialFirstPlaceWins = rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] or 0,
    classOptimizationPeakHp = rtState.classOptimizationPeakHpByBusiness[id] or {},
    dynoRequired = rtState.dynoRequiredByBusiness[id] or {},
    league2InviteOfferedAt = (rtState.league2InviteByBusiness[id] or {}).offeredAt,
    league2InviteDeclined = (rtState.league2InviteByBusiness[id] or {}).declined == true,
    league2InviteTargetLeague = (rtState.league2InviteByBusiness[id] or {}).targetLeague,
    racingTeamSponsors = rtState.rtInternal.sponsors[id],
    league2InvitePromoUi = rtState.league2InvitePromoUiByBusiness[id],
    purchaseMilestoneSplashShown = rtState.purchaseMilestoneSplashShownByBusiness[id] == true,
    raceUnlockSplashPending = rtState.raceUnlockSplashPendingByBusiness[id] == true,
    raceUnlockSplashShown = rtState.raceUnlockSplashShownByBusiness[id] == true,
    careerFinaleSplashPending = rtState.careerFinaleSplashPendingByBusiness[id] == true,
    careerFinaleSplashShown = rtState.careerFinaleSplashShownByBusiness[id] == true,
    autoStartBackgroundRaces = rtState.autoStartBackgroundRacesByBusiness[id] ~= false,
    activeBackgroundRaceSim = racingTeamRaceSim.getPersistedStateForSave(id),
    vehicleCooldowns = (function()
      local out = {}
      local now = os.time()
      for vidKey, rec in pairs(rtState.vehicleCooldownByBusiness[id] or {}) do
        if type(rec) == "table" and ((tonumber(rec.wallEpoch) or 0) > now) then
          out[tostring(vidKey)] = { untilSim = rec.untilSim, wallEpoch = rec.wallEpoch }
        end
      end
      return out
    end)(),
    playerCooldown = (function()
      local rec = rtState.playerCooldownByBusiness[id]
      if type(rec) ~= "table" then
        return nil
      end
      if (tonumber(rec.wallEpoch) or 0) <= os.time() then
        return nil
      end
      return { untilSim = rec.untilSim, wallEpoch = rec.wallEpoch }
    end)(),
    allLeaderboardsBaselines = (function()
      local out = {}
      for gid, arr in pairs(rtState.allLeaderboardsBaselineByBusiness[id] or {}) do
        if type(arr) == "table" and #arr > 0 then
          local rows = {}
          for _, e in ipairs(arr) do
            table.insert(rows, {
              raceType = e.raceType,
              raceLabel = e.raceLabel,
              baselineSec = e.baselineSec,
            })
          end
          out[gid] = rows
        end
      end
      return out
    end)(),
    completedGoalLeaderboardTimes = (function()
      local out = {}
      for gid, snap in pairs(rtState.completedGoalLeaderboardTimesByBusiness[id] or {}) do
        if type(snap) == "table" and snap.kind == "single" then
          out[gid] = { kind = "single", bestSec = snap.bestSec }
        elseif type(snap) == "table" and snap.kind == "tracks" and type(snap.tracks) == "table" and #snap.tracks > 0 then
          local rows = {}
          for _, e in ipairs(snap.tracks) do
            table.insert(rows, {
              raceType = e.raceType,
              raceLabel = e.raceLabel,
              bestSec = e.bestSec,
            })
          end
          out[gid] = { kind = "tracks", tracks = rows }
        end
      end
      return out
    end)(),
  }
  jsonWriteFile(filePath, data, true)
end

function getOfferState(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  if not rtState.offerStateByBusiness[id] then
    rtState.offerStateByBusiness[id] = {
      active = {},
      new = {}
    }
  end
  if not rtState.persistLoaded[id] then
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.persistLoaded[id] = true
      loadRacingTeamPersistedState(businessId, rtState.offerStateByBusiness[id])
    end
  end
  return rtState.offerStateByBusiness[id]
end

local function ensureTabsRegistered()
  if not career_modules_business_businessTabRegistry then
    return false
  end

  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "home",
    label = "Home",
    icon = '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>',
    component = "BusinessHomeView",
    section = "BASIC",
    order = 1
  })
  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "jobs",
    label = "Goals",
    icon = '<path d="M9 11l3 3L22 4M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
    component = "BusinessJobsTab",
    section = "BASIC",
    order = 2
  })
  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "vehicles",
    label = "Vehicles",
    icon = '<path d="M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2"/><circle cx="7" cy="17" r="2"/><path d="M9 17h6"/><circle cx="17" cy="17" r="2"/>',
    component = "BusinessVehiclesTab",
    section = "BASIC",
    order = 3
  })
  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "inventory",
    label = "Inventory",
    icon = '<path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
    component = "BusinessInventoryTab",
    section = "BASIC",
    order = 3.5
  })
  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "race",
    label = "Race",
    icon = '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
    component = "BusinessRacingTab",
    section = "BASIC",
    order = 4
  })
  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "drivers",
    label = "Drivers",
    icon = '<circle cx="12" cy="7" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/><circle cx="19" cy="7" r="3"/><path d="M22 21v-2a3 3 0 0 0-3-3h-2"/>',
    component = "BusinessDriversTab",
    section = "BASIC",
    order = 5
  })
  career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
    id = "finances",
    label = "Finances",
    icon = '<path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>',
    component = "BusinessFinancesTab",
    section = "BASIC",
    order = 6
  })
  local devConsole = rawget(_G, "career_modules_devConsole")
  if not (devConsole and devConsole.isEnabled) then
    local ok, mod = pcall(require, "ge/extensions/career/modules/devConsole")
    if ok then
      devConsole = mod
    end
  end
  if devConsole and devConsole.isEnabled and devConsole.isEnabled() then
    career_modules_business_businessTabRegistry.registerTab(rtState.businessType, {
      id = "dev-console",
      label = "Dev Console",
      icon = '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 12h8M12 8v8"/>',
      component = "BusinessRacingTeamDevConsoleTab",
      section = "BASIC",
      order = 200
    })
  else
    career_modules_business_businessTabRegistry.unregisterTab(rtState.businessType, "dev-console")
  end
  return true
end

local function getCareerSimTime()
  if gameplay_events_freContracts_state and gameplay_events_freContracts_state.getState then
    local s = gameplay_events_freContracts_state.getState()
    local t = tonumber(s and s.simTime)
    if t then
      return t
    end
  end
  return os.time()
end

-- === Cooldowns (delegated to racingTeamFleet)
local function getRacingTeamPostRaceCooldownSeconds(businessId) return racingTeamFleet.getRacingTeamPostRaceCooldownSeconds(businessId) end
local function getFleetVehiclePostRaceCooldownRemainingSec(businessId, vehicleId) return racingTeamFleet.getFleetVehiclePostRaceCooldownRemainingSec(businessId, vehicleId) end
local function armFleetVehiclePostRaceCooldown(businessId, vehicleId) return racingTeamFleet.armFleetVehiclePostRaceCooldown(businessId, vehicleId) end
local function getRacingTeamPlayerPostRaceCooldownSeconds(businessId) return racingTeamFleet.getRacingTeamPlayerPostRaceCooldownSeconds(businessId) end
local function getPlayerPostRaceCooldownRemainingSec(businessId) return racingTeamFleet.getPlayerPostRaceCooldownRemainingSec(businessId) end
local function armPlayerPostRaceCooldown(businessId) return racingTeamFleet.armPlayerPostRaceCooldown(businessId) end
local function getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) return racingTeamFleet.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) end

function M.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
  return racingTeamFleet.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
end

local function getRacingTeamLevelId()
  if gameplay_events_freContracts_state and gameplay_events_freContracts_state.getCurrentLevelId then
    local lid = gameplay_events_freContracts_state.getCurrentLevelId()
    if type(lid) == "string" and lid ~= "" then
      return lid
    end
  end
  if getCurrentLevelIdentifier then
    local g = getCurrentLevelIdentifier()
    if type(g) == "string" and g ~= "" then
      return g
    end
  end
  return ""
end

local function resolveRacingTeamLeaderboardLevelIds()
  local out = {}
  local seen = {}
  for lid, _ in pairs(rtState.K.RACING_TEAM_LEVEL_INFO_FILE_BY_LEVEL or {}) do
    if type(lid) == "string" and lid ~= "" and not seen[lid] then
      seen[lid] = true
      table.insert(out, lid)
    end
  end
  local cur = getRacingTeamLevelId()
  if type(cur) == "string" and cur ~= "" and not seen[cur] then
    seen[cur] = true
    table.insert(out, cur)
  end
  return out
end

local function shallowCopyTable(t)
  local o = {}
  if type(t) == "table" then
    for k, v in pairs(t) do
      o[k] = v
    end
  end
  return o
end

local function getRacingTeamLevelInfo(levelId)
  local function getRacingTeamLevelInfoJsonCandidates(lid)
    local list = {}
    if type(lid) ~= "string" or lid == "" then
      return list
    end
    local alias = rtState.K.RACING_TEAM_LEVEL_INFO_FILE_BY_LEVEL[lid]
    if type(alias) == "string" and alias ~= "" then
      table.insert(list, "levels/" .. lid .. "/" .. alias)
    end
    table.insert(list, "levels/" .. lid .. "/racingTeam_info.json")
    table.insert(list, "levels/" .. lid .. "/" .. lid .. "_racingTeam_info.json")
    return list
  end

  local function loadRacingTeamLevelInfoJsonRaw(lid)
    for _, path in ipairs(getRacingTeamLevelInfoJsonCandidates(lid)) do
      if FS and FS.fileExists and FS:fileExists(path) then
        local data = jsonReadFile(path)
        if data and type(data) == "table" then
          return data
        end
      end
    end
    return nil
  end

  local LEAGUE_INVITE_DEFAULTS_BY_TARGET = {
    [2] = { orgName = "Amateur Racing Association", acronym = "ARA", feeEarly = 1500, feeLate = 2500, feeEscalateMinutes = 60 },
    [3] = { orgName = "National Racing Council",   acronym = "NRC", feeEarly = 2500, feeLate = 3500, feeEscalateMinutes = 60 },
    [4] = { orgName = "Professional Motorsports Alliance", acronym = "PMA", feeEarly = 3500, feeLate = 4500, feeEscalateMinutes = 60 },
  }

  local function normalizeRacingTeamLevelInfo(raw, lid)
  local function setIfString(o, key, val)
    if type(val) == "string" and val ~= "" then
      o[key] = val
    end
  end

  local o = {
    sponsorFocusLabel = nil,
    msgWelcomeToastTitle = nil,
    msgRaceOffersLeague2 = nil,
    msgProxyRaceScheduledToastTitle = nil,
    msgNoSanctionedRaces = nil,
    leagueDisplayNames = {},
    extra = {},
    splashPurchaseTitle = nil,
    splashPurchaseBody = nil,
    splashPurchaseContinueLabel = nil,
    splashPurchaseImageUrl = nil,
    splashCareerFinaleTitle = nil,
    splashCareerFinaleBody = nil,
    splashCareerFinaleContinueLabel = nil,
    splashCareerFinaleImageUrl = nil,
  }
  for n = 2, 4 do
    local d = LEAGUE_INVITE_DEFAULTS_BY_TARGET[n]
    o[string.format("league%dInviteOrgName", n)] = d.orgName
    o[string.format("league%dInviteAcronym", n)] = d.acronym
    o[string.format("league%dInviteFeeEarly", n)] = d.feeEarly
    o[string.format("league%dInviteFeeLate", n)] = d.feeLate
    o[string.format("league%dInviteFeeEscalateMinutes", n)] = d.feeEscalateMinutes
    o[string.format("league%dBankReasonShort", n)] = nil
    o[string.format("splashLeague%dTitle", n)] = nil
    o[string.format("splashLeague%dBody", n)] = nil
    o[string.format("splashLeague%dAcceptLabel", n)] = nil
    o[string.format("splashLeague%dLaterLabel", n)] = nil
    o[string.format("splashLeague%dImageUrl", n)] = nil
    o[string.format("splashLeague%dWelcomeTitle", n)] = nil
    o[string.format("splashLeague%dWelcomeBody", n)] = nil
    o[string.format("splashLeague%dWelcomeContinueLabel", n)] = nil
    o[string.format("splashLeague%dWelcomeImageUrl", n)] = nil
    o[string.format("msgWelcomeLeague%d", n)] = nil
  end

  if type(raw) == "table" then
    for n = 2, 4 do
      local inv = raw[string.format("league%dInvite", n)]
      if type(inv) == "table" then
        setIfString(o, string.format("league%dInviteOrgName", n), inv.orgName)
        setIfString(o, string.format("league%dInviteAcronym", n), inv.acronym)
        local fe = tonumber(inv.feeEarly)
        if fe and fe > 0 then o[string.format("league%dInviteFeeEarly", n)] = math.floor(fe) end
        local fl = tonumber(inv.feeLate)
        if fl and fl > 0 then o[string.format("league%dInviteFeeLate", n)] = math.floor(fl) end
        local em = tonumber(inv.feeEscalateMinutes)
        if em and em > 0 then o[string.format("league%dInviteFeeEscalateMinutes", n)] = math.floor(em) end
        setIfString(o, string.format("league%dBankReasonShort", n), inv.bankReasonShort)
      end
    end
    local sp = raw.sponsorOffer
    if type(sp) == "table" and type(sp.focusLabel) == "string" and sp.focusLabel ~= "" then
      o.sponsorFocusLabel = sp.focusLabel
    end
    local msg = raw.messages
    if type(msg) == "table" then
      setIfString(o, "msgWelcomeLeague2", msg.welcomeLeague2)
      setIfString(o, "msgWelcomeLeague3", msg.welcomeLeague3)
      setIfString(o, "msgWelcomeLeague4", msg.welcomeLeague4)
      setIfString(o, "msgWelcomeToastTitle", msg.welcomeToastTitle)
      setIfString(o, "msgRaceOffersLeague2", msg.raceOffersLeague2)
      setIfString(o, "msgProxyRaceScheduledToastTitle", msg.proxyRaceScheduledToastTitle)
    end
    local hints = raw.hints
    if type(hints) == "table" and type(hints.noSanctionedRaces) == "string" and hints.noSanctionedRaces ~= "" then
      o.msgNoSanctionedRaces = hints.noSanctionedRaces
    end
    if type(raw.leagueDisplayNames) == "table" then
      o.leagueDisplayNames = shallowCopyTable(raw.leagueDisplayNames)
    end
    if type(raw.extra) == "table" then
      o.extra = shallowCopyTable(raw.extra)
    end
    local sps = raw.splashes
    if type(sps) == "table" then
      local pu = sps.purchase
      if type(pu) == "table" then
        setIfString(o, "splashPurchaseTitle", pu.title)
        setIfString(o, "splashPurchaseBody", pu.body)
        setIfString(o, "splashPurchaseContinueLabel", pu.continueLabel)
        setIfString(o, "splashPurchaseImageUrl", pu.imageUrl)
      end
      local cf = sps.careerFinale
      if type(cf) == "table" then
        setIfString(o, "splashCareerFinaleTitle", cf.title)
        setIfString(o, "splashCareerFinaleBody", cf.body)
        setIfString(o, "splashCareerFinaleContinueLabel", cf.continueLabel)
        setIfString(o, "splashCareerFinaleImageUrl", cf.imageUrl)
      end
      for n = 2, 4 do
        local l = sps[string.format("league%d", n)]
        if type(l) == "table" then
          setIfString(o, string.format("splashLeague%dTitle", n), l.title)
          setIfString(o, string.format("splashLeague%dBody", n), l.body)
          setIfString(o, string.format("splashLeague%dAcceptLabel", n), l.acceptLabel)
          setIfString(o, string.format("splashLeague%dLaterLabel", n), l.laterLabel)
          setIfString(o, string.format("splashLeague%dImageUrl", n), l.imageUrl)
        end
        local lw = sps[string.format("league%dWelcome", n)]
        if type(lw) == "table" then
          setIfString(o, string.format("splashLeague%dWelcomeTitle", n), lw.title)
          setIfString(o, string.format("splashLeague%dWelcomeBody", n), lw.body)
          setIfString(o, string.format("splashLeague%dWelcomeContinueLabel", n), lw.continueLabel)
          setIfString(o, string.format("splashLeague%dWelcomeImageUrl", n), lw.imageUrl)
        end
      end
    end
  end

  local ac2 = o.league2InviteAcronym
  if not o.sponsorFocusLabel or o.sponsorFocusLabel == "" then
    o.sponsorFocusLabel = ac2 .. " team racing"
  end
  if not o.msgRaceOffersLeague2 or o.msgRaceOffersLeague2 == "" then
    o.msgRaceOffersLeague2 =
      ac2 .. " management: assign proxy races from the Drivers tab (rolled events — no job board)."
  end
  if not o.msgWelcomeToastTitle or o.msgWelcomeToastTitle == "" then
    o.msgWelcomeToastTitle = ac2
  end
  if not o.msgProxyRaceScheduledToastTitle or o.msgProxyRaceScheduledToastTitle == "" then
    o.msgProxyRaceScheduledToastTitle = ac2
  end
  if not o.msgNoSanctionedRaces or o.msgNoSanctionedRaces == "" then
    o.msgNoSanctionedRaces =
      "No sanctioned race offers yet. Keep working through your team goals — circuit offers unlock as you progress."
  end
  if not o.splashPurchaseTitle or o.splashPurchaseTitle == "" then
    o.splashPurchaseTitle = "Welcome"
  end
  if not o.splashPurchaseBody or o.splashPurchaseBody == "" then
    o.splashPurchaseBody =
      "You own the racing team. Open the business computer and work through goals to grow the program."
  end
  if not o.splashPurchaseContinueLabel or o.splashPurchaseContinueLabel == "" then
    o.splashPurchaseContinueLabel = "Continue"
  end
  if not o.splashCareerFinaleTitle or o.splashCareerFinaleTitle == "" then
    o.splashCareerFinaleTitle = "Well done indeed"
  end
  if not o.splashCareerFinaleBody or o.splashCareerFinaleBody == "" then
    o.splashCareerFinaleBody =
      "Look how far you've come..... what started as a few bucks and a dream has turned into a career. You know what they say, \"find something you love to do and you'll never work a day in your life\"\n\n"
        .. "How does it feel? National recognition, dreams realized? You've made it. Enjoy this career you've built - keep pushing the envelope and competing - it doesn't get any easier, but, you know that by now.\n\n"
        .. "Congratulations kid, well done indeed"
  end
  if not o.splashCareerFinaleContinueLabel or o.splashCareerFinaleContinueLabel == "" then
    o.splashCareerFinaleContinueLabel = "Continue"
  end

  for n = 2, 4 do
    local ac = o[string.format("league%dInviteAcronym", n)]
    local titleKey = string.format("splashLeague%dTitle", n)
    if not o[titleKey] or o[titleKey] == "" then
      o[titleKey] = ac .. " invitation"
    end
    local bodyKey = string.format("splashLeague%dBody", n)
    if not o[bodyKey] or o[bodyKey] == "" then
      if n == 2 then
        o[bodyKey] =
          "Tier one is complete. You can register with " .. ac
            .. " now (fee from your business account) or choose Later and decide from the Goals tab."
      else
        o[bodyKey] = string.format(
          "Your league %d objectives are complete. Register with %s to advance into a higher league — tougher cars, tighter fields, bigger stakes. Fee posts to your team account when you accept, or choose Later and decide from the Goals tab.",
          n - 1, ac
        )
      end
    end
    local accKey = string.format("splashLeague%dAcceptLabel", n)
    if not o[accKey] or o[accKey] == "" then o[accKey] = "Accept" end
    local latKey = string.format("splashLeague%dLaterLabel", n)
    if not o[latKey] or o[latKey] == "" then o[latKey] = "Later" end

    local welTitleKey = string.format("splashLeague%dWelcomeTitle", n)
    if not o[welTitleKey] or o[welTitleKey] == "" then
      o[welTitleKey] = "You're in"
    end
    local welBodyKey = string.format("splashLeague%dWelcomeBody", n)
    if not o[welBodyKey] or o[welBodyKey] == "" then
      if n == 2 then
        o[welBodyKey] =
          "Registration fee posted to your team account. Welcome to the regional grid — hire drivers, keep the cars healthy, and use the Race tab when you are ready to run."
      else
        o[welBodyKey] = string.format(
          "Registration fee posted. You are now competing in %s — keep the operation tight, hire drivers who can hold position, and use the Race tab when you are ready to run.",
          ac
        )
      end
    end
    local welContKey = string.format("splashLeague%dWelcomeContinueLabel", n)
    if not o[welContKey] or o[welContKey] == "" then o[welContKey] = "Let's Go!" end

    local msgWelKey = string.format("msgWelcomeLeague%d", n)
    if not o[msgWelKey] or o[msgWelKey] == "" then
      o[msgWelKey] = "Welcome to " .. ac .. " — hire drivers and run sanctioned races."
    end
  end
  return o
end

  local lid = ""
  if type(levelId) == "string" then
    lid = levelId
  end
  local cached = rtState.rtInternal.racingTeamLevelInfoNormalizedCache[lid]
  if cached then
    return cached
  end
  local raw = nil
  if lid ~= "" then
    raw = loadRacingTeamLevelInfoJsonRaw(lid)
  end
  local n = normalizeRacingTeamLevelInfo(raw, lid)
  rtState.rtInternal.racingTeamLevelInfoNormalizedCache[lid] = n
  return n
end

-- === Race offer board (delegated to racingTeamRaceOffers)
local function getRaceOfferBoard(businessId) return racingTeamRaceOffers.getBoard(businessId) end
local function getPendingRematchOffer(businessId) return racingTeamRaceOffers.getPendingRematch(businessId) end
local function setPendingRematchOffer(businessId, offer) return racingTeamRaceOffers.setPendingRematch(businessId, offer) end
local function removeOfferById(board, offerId) return racingTeamRaceOffers.removeOfferById(board, offerId) end
local function normalizeLineupSnapshot(list) return racingTeamRaceOffers.normalizeLineupSnapshot(list) end
local function lineupMaxPw(lineup, fallbackPw) return racingTeamRaceOffers.lineupMaxPw(lineup, fallbackPw) end
local function ensurePendingRematchOnBoard(businessId) return racingTeamRaceOffers.ensurePendingRematchOnBoard(businessId) end

-- === Vehicle valuation / PW / branch (delegated to racingTeamFleet)
local function getCatalogVehicleInfo(mk, ck) return racingTeamFleet.getCatalogVehicleInfo(mk, ck) end
local function getTeamVehicleBookValue(vehicle) return racingTeamFleet.getTeamVehicleBookValue(vehicle) end
local function getTeamVehicleSellValue(vehicle, fallbackValue) return racingTeamFleet.getTeamVehicleSellValue(vehicle, fallbackValue) end

local function jobIdsMatch(sentJobId, offerJobId)
  local a = tonumber(sentJobId) or sentJobId
  local b = tonumber(offerJobId) or offerJobId
  return a == b
end

local function getEffectiveTeamJobVehicleHp(businessId, vehicle) return racingTeamFleet.getEffectiveTeamJobVehicleHp(businessId, vehicle) end
local function getEffectiveTeamJobVehiclePw(businessId, vehicle) return racingTeamFleet.getEffectiveTeamJobVehiclePw(businessId, vehicle) end
local function resolveFleetVehicleSanctionedBranch(businessId, vehicle) return racingTeamFleet.resolveFleetVehicleSanctionedBranch(businessId, vehicle) end
local function getSanctionedBranchFilterForBusiness(businessId) return racingTeamFleet.getSanctionedBranchFilterForBusiness(businessId) end

local function bumpRaceOfferBoardRefresh(businessId) return racingTeamRaceOffers.bumpRefresh(businessId) end
local function rollOneRaceOffer(levelId, now, options) return racingTeamRaceOffers.rollOneOffer(levelId, now, options) end
local function ensureRaceOfferBoard(businessId) return racingTeamRaceOffers.ensureBoard(businessId) end
local function topUpRaceOffers(businessId) return racingTeamRaceOffers.topUp(businessId) end

-- === Damage (delegated to racingTeamFleet)
local function getDamageThreshold(businessId) return racingTeamFleet.getDamageThreshold(businessId) end
local function getSpawnedBusinessVehicleDamageInfo(businessId, vehicleId) return racingTeamFleet.getSpawnedBusinessVehicleDamageInfo(businessId, vehicleId) end

local function getMaxPulledOutVehicles(businessId)
  local cap = rtState.K.RACING_TEAM_GARAGE_PARKING_CAP or 4
  local slotLv = getRacingTeamGarageSlotsSkillLevel(businessId)
  local function clampPulls(n)
    return math.min(cap, math.max(1, math.floor(tonumber(n) or 1)))
  end
  local isLeague1 = rtState.rtInternal.getCurrentLeague(businessId) == "league1"
  local base = (not isLeague1 or rtState.rtInternal.allTierOneGoalsComplete(businessId)) and 2 or 1
  return clampPulls(base + slotLv)
end

local function getMaxActiveJobs(businessId)
  local cap = rtState.K.RACING_TEAM_GARAGE_PARKING_CAP or 4
  local n = 2 + getRacingTeamGarageSlotsSkillLevel(businessId)
  return math.min(cap, math.max(1, n))
end

rtState.rtInternal.getCurrentLeague = function(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  getOfferState(businessId)
  local v = rtState.currentLeagueByBusiness[id]
  if type(v) == "string" and v ~= "" then
    return v
  end
  return "league1"
end

local function leagueRankFromId(leagueId)
  local n = tonumber(string.match(tostring(leagueId or ""), "^league(%d+)$"))
  return n or 0
end

rtState.rtInternal.leagueRankFromId = leagueRankFromId

rtState.rtInternal.isLeagueAtLeast = function(leagueId, minRank)
  return leagueRankFromId(leagueId) >= (tonumber(minRank) or 2)
end

rtState.rtInternal.isCurrentLeagueAtLeast = function(businessId, minRank)
  return rtState.rtInternal.isLeagueAtLeast(rtState.rtInternal.getCurrentLeague(businessId), minRank)
end

local function getActiveGoalsList(businessId) return racingTeamGoals.getActiveList(businessId) end
local function getCompletedGoalsList(businessId) return racingTeamGoals.getCompletedList(businessId) end
local function buildRacingTeamGoalDisplays(businessId) return racingTeamGoals.buildDisplays(businessId) end

local function getRacingTeamDriverCapacity(businessId)
  if rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    return 0
  end
  return 1 + getSkillTreeNodeLevel(businessId, "driver", "expanded-roster")
end

local function getRacingTeamDriversSavePath(businessId, currentSavePath)
  if not currentSavePath or not businessId then
    return nil
  end
  return currentSavePath .. "/career/rls_career/businesses/" .. tostring(businessId) .. "/racingDrivers.json"
end

local function saveRacingTeamDrivers(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not rtState.businessDrivers[businessId] or not currentSavePath then
    return
  end
  local filePath = getRacingTeamDriversSavePath(businessId, currentSavePath)
  if not filePath then
    return
  end
  local dirPath = string.match(filePath, "^(.*)/[^/]+$")
  if dirPath and FS and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  jsonWriteFile(filePath, { techs = rtState.businessDrivers[businessId] }, true)
end

local function ensureRacingDriverIdentity(tech, index)
  if not tech.id then
    tech.id = index
  end
  if not tech.name or tech.name == "" then
    tech.name = string.format("Driver #%d", tonumber(tech.id) or index or 1)
  end
  tech.fired = tech.fired or false
  tech.currentAction = tech.currentAction or "idle"
  tech.state = tech.state or 0
  tech.stateElapsed = tech.stateElapsed or 0
  tech.stateDuration = tech.stateDuration or 0
  tech.racingSkillXp = math.max(0, math.floor(tonumber(tech.racingSkillXp) or 0))
  tech.sanctionedRacesFinished = math.max(0, math.floor(tonumber(tech.sanctionedRacesFinished) or 0))
  tech.sanctionedRaceWins = math.max(0, math.floor(tonumber(tech.sanctionedRaceWins) or 0))
  tech.sanctionedPodiums = math.max(0, math.floor(tonumber(tech.sanctionedPodiums) or 0))
end

local function ensureRacingTeamDriverSlots(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local capacity = math.max(0, getRacingTeamDriverCapacity(businessId))
  local techs = rtState.businessDrivers[businessId] or {}
  for _, tech in ipairs(techs) do
    ensureRacingDriverIdentity(tech, tech.id)
  end
  local maxId = 0
  for _, tech in ipairs(techs) do
    if tech.id and tech.id > maxId then
      maxId = tech.id
    end
  end
  local nextId = maxId + 1
  while #techs < capacity do
    local newTech = {
      id = nextId,
      name = string.format("Driver #%d", nextId),
      fired = true,
      currentAction = "idle",
      state = 0,
      stateElapsed = 0,
      stateDuration = 0,
      jobId = nil,
    }
    ensureRacingDriverIdentity(newTech, nextId)
    table.insert(techs, newTech)
    nextId = nextId + 1
  end
  rtState.businessDrivers[businessId] = techs
end

-- === League invite / promotion / milestone splashes (delegated to racingTeamLeagueInvite)
-- The rtInternal helpers (getLeagueInviteConfigForTarget, LEAGUE_PROMOTION_NEXT,
-- getNextLeagueForPromotion, triggerRacingTeamMilestoneSplashShow,
-- scheduleLeague2WelcomeSplash, schedulePurchaseMilestoneSplash,
-- refreshLeague2InviteOffer) are defined inside racingTeamLeagueInvite.lua at
-- require time so cross-sibling callers continue to work.
local function getLeague2InviteTable(businessId) return racingTeamLeagueInvite.getInviteTable(businessId) end
local function getLeague2InviteFeeAmount(businessId) return racingTeamLeagueInvite.feeAmount(businessId) end
local function acceptLeague2Invite(businessId) return racingTeamLeagueInvite.accept(businessId) end
local function declineLeague2Invite(businessId) return racingTeamLeagueInvite.decline(businessId) end
local function racingTeamMilestoneLeague2Later(businessId) return racingTeamLeagueInvite.milestoneLeague2Later(businessId) end
local function racingTeamMilestoneLeague2WelcomeContinue(businessId) return racingTeamLeagueInvite.milestoneLeague2WelcomeContinue(businessId) end
local function racingTeamMilestoneLeague2Accept(businessId) return racingTeamLeagueInvite.milestoneLeague2Accept(businessId) end
local function racingTeamMilestonePurchaseContinue(businessId) return racingTeamLeagueInvite.milestonePurchaseContinue(businessId) end
local function racingTeamMilestoneCareerFinaleContinue(businessId) return racingTeamLeagueInvite.milestoneCareerFinaleContinue(businessId) end

-- === Sponsors (delegated to racingTeamSponsors)
local function getRacingTeamSponsorState(businessId) return racingTeamSponsors.getState(businessId) end
local function racingTeamSponsorBonusTotals(businessId) return racingTeamSponsors.bonusTotals(businessId) end
local function tickRacingTeamSponsorOffers(businessId) return racingTeamSponsors.tickOffers(businessId) end
local function acceptRacingTeamSponsorOffer(businessId, offerId) return racingTeamSponsors.acceptOffer(businessId, offerId) end
local function declineRacingTeamSponsorOffer(businessId, offerId) return racingTeamSponsors.declineOffer(businessId, offerId) end
local function dropRacingTeamSponsorActive(businessId, offerId) return racingTeamSponsors.dropActive(businessId, offerId) end

rtState.loadRacingTeamDrivers = function(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return {}
  end
  local function ensurePendingOfferWallDeadlineForTech(tech)
    local pr = tech and tech.pendingRaceOffer
    if not pr or type(pr) ~= "table" then
      return
    end
    local simDue = tonumber(pr.scheduledRaceSimTime)
    if not simDue then
      return
    end
    if tonumber(pr.scheduledRaceReadyWallEpoch) then
      return
    end
    local rem = math.max(0, math.ceil(simDue - getCareerSimTime()))
    pr.scheduledRaceReadyWallEpoch = os.time() + rem
  end
  local function ensurePostRaceCooldownWallDeadlineForTech(tech)
    if not tech or type(tech) ~= "table" then
      return
    end
    local untilSim = tonumber(tech.racingCooldownUntilSimTime)
    if not untilSim then
      tech.postRaceCooldownReadyWallEpoch = nil
      return
    end
    local wallEpoch = tonumber(tech.postRaceCooldownReadyWallEpoch)
    if wallEpoch and wallEpoch > 0 and os.time() >= wallEpoch then
      tech.racingCooldownUntilSimTime = nil
      tech.postRaceCooldownReadyWallEpoch = nil
      return
    end
    local nowSim = getCareerSimTime()
    if nowSim >= untilSim then
      tech.racingCooldownUntilSimTime = nil
      tech.postRaceCooldownReadyWallEpoch = nil
      return
    end
    if wallEpoch and wallEpoch > 0 then
      return
    end
    local remSim = math.max(0, math.ceil(untilSim - nowSim))
    tech.postRaceCooldownReadyWallEpoch = os.time() + remSim
  end
  if rtState.businessDrivers[businessId] then
    ensureRacingTeamDriverSlots(businessId)
    for _, tech in ipairs(rtState.businessDrivers[businessId]) do
      ensurePendingOfferWallDeadlineForTech(tech)
      ensurePostRaceCooldownWallDeadlineForTech(tech)
    end
    return rtState.businessDrivers[businessId]
  end
  local techs = {}
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    local filePath = getRacingTeamDriversSavePath(businessId, savePath)
    if filePath and FS and FS.fileExists and FS:fileExists(filePath) then
      local data = jsonReadFile(filePath)
      if data and type(data) == "table" and type(data.techs) == "table" then
        for index, tech in ipairs(data.techs) do
          ensureRacingDriverIdentity(tech, tech.id or index)
          ensurePendingOfferWallDeadlineForTech(tech)
          ensurePostRaceCooldownWallDeadlineForTech(tech)
          table.insert(techs, tech)
        end
      end
    end
  end
  rtState.businessDrivers[businessId] = techs
  ensureRacingTeamDriverSlots(businessId)
  return rtState.businessDrivers[businessId]
end

local function getRacingTeamDriversRawForUI(businessId)
  if getRacingTeamDriverCapacity(businessId) < 1 then
    return {}
  end
  return rtState.loadRacingTeamDrivers(businessId)
end

local function getRacingTeamDriverById(businessId, techId)
  techId = tonumber(techId)
  if not techId then
    return nil
  end
  for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    if tonumber(tech.id) == techId then
      return tech
    end
  end
  return nil
end

local function getRacingTeamActiveJobByJobId(businessId, jobId)
  local state = getOfferState(businessId)
  for _, job in ipairs(state.active or {}) do
    if jobIdsMatch(jobId, job.jobId) then
      return job
    end
  end
  return nil
end

local function getBusinessVehicleRawByInventoryId(businessId, vehicleId)
  if not vehicleId or not career_modules_business_businessInventory then
    return nil
  end
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  for _, v in ipairs(vehicles) do
    local vid = tonumber(v.vehicleId) or v.vehicleId
    if jobIdsMatch(vehicleId, vid) then
      return v
    end
  end
  return nil
end

local function sanctionedOfferMatchesFleetVehicle(businessId, fleetVehicleId, offer)
  if type(offer) ~= "table" or fleetVehicleId == nil then
    return false
  end
  local raw = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  if not raw then
    return false
  end
  local pw = getEffectiveTeamJobVehiclePw(businessId, raw)
  if not pw then
    return false
  end
  local lo = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hi = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or lo
  if hi < lo then
    lo, hi = hi, lo
  end
  return pw >= lo and pw <= hi
end

local function fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, offer)
  if type(offer) ~= "table" or fleetVehicleId == nil then
    return false
  end
  local raw = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  if not raw then
    return false
  end
  local pw = getEffectiveTeamJobVehiclePw(businessId, raw)
  if not pw then
    return false
  end
  local lo = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hi = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or lo
  if hi < lo then
    lo, hi = hi, lo
  end
  return pw > hi
end

local function fleetVehicleEligibleForOffer(businessId, fleetVehicleId, offer)
  if type(offer) ~= "table" or fleetVehicleId == nil then
    return false
  end
  local raw = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  if not raw then
    return false
  end
  local pw = getEffectiveTeamJobVehiclePw(businessId, raw)
  if not pw then
    return false
  end
  local lo = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hi = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or lo
  if hi < lo then
    lo, hi = hi, lo
  end
  return pw <= hi
end

local notifyRacingTeamDriversUpdated
local racingTeamPersistDrivers

local function acceptRacingTeamRaceOffer(businessId, offerId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or offerId == nil or not techId then
    return false
  end
  if rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired then
    return false
  end
  if tech.jobId or tech.pendingRaceOffer then
    return false
  end
  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId or not getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    return false
  end
  if getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) > 0 then
    if ui_message then
      ui_message(
        string.format("%s is still recovering from their last race.", tech.name or "Driver"),
        6,
        "Racing Team",
        "warning"
      )
    end
    return false
  end
  local board = getRaceOfferBoard(businessId)
  local want = tostring(offerId)
  local idx = nil
  local picked = nil
  for i, o in ipairs(board.offers or {}) do
    if o and tostring(o.id) == want then
      idx = i
      picked = o
      break
    end
  end
  if not idx or not picked then
    return false
  end
  if showDynoRequiredMessageIfBlocked(businessId, fleetVehicleId, picked) then
    return "dyno_required"
  end
  if fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, picked) then
    if guihooks then
      guihooks.trigger("racingTeam:vehicleOutOfClass", { businessId = tostring(businessId) })
    end
    rtDevLog(businessId, "warn", "Fleet vehicle out of class for offer", "race", { vehicleId = fleetVehicleId })
    return "out_of_class"
  end
  if not fleetVehicleEligibleForOffer(businessId, fleetVehicleId, picked) then
    local rawEl = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
    local pwEl = rawEl and getEffectiveTeamJobVehiclePw(businessId, rawEl)
    if not pwEl then
      if ui_message then
        ui_message(
          "Cannot read this fleet car's power-to-weight (dyno or curb weight missing). Try a dyno pull or another car.",
          10,
          "Racing Team",
          "warning"
        )
      end
      rtDevLog(businessId, "warn", "Fleet power/weight unknown for offer", "race", { vehicleId = fleetVehicleId })
      return "fleet_power_weight_unknown"
    end
    if ui_message then
      ui_message("This fleet car is outside the race's power-to-weight bracket.", 8, "Racing Team", "warning")
    end
    rtDevLog(businessId, "warn", "Fleet vehicle outside P/W bracket", "race", { vehicleId = fleetVehicleId })
    return "not_eligible_pw"
  end
  local rem = getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId)
  if rem > 0 then
    if guihooks then
      guihooks.trigger("racingTeam:vehicleOnCooldown", {
        businessId = tostring(businessId),
        vehicleId = tostring(fleetVehicleId),
        remainingSec = rem,
      })
    end
    rtDevLog(businessId, "warn", "Fleet vehicle on cooldown (" .. tostring(math.ceil(rem)) .. "s)", "race", { vehicleId = fleetVehicleId })
    return "vehicle_cooldown"
  end
  if not racingTeamFinances.tryDebitRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId)) then
    if ui_message then
      ui_message("Not enough funds in the team account for the race entry fee.", 6, "Racing Team", "warning")
    end
    rtDevLog(businessId, "warn", "Race entry fee debit failed", "race")
    return false
  end
  local srHp = gameplay_events_freContracts_sanctionedRacing
  if srHp and type(srHp.attachSanctionedOfferDisplayHp) == "function" then
    srHp.attachSanctionedOfferDisplayHp(picked)
  end
  table.remove(board.offers, idx)
  local pending = {}
  for k, v in pairs(picked) do
    pending[k] = v
  end
  local schedDelaySec = math.random(rtState.K.SCHEDULED_RACE_MIN_SEC, rtState.K.SCHEDULED_RACE_MAX_SEC)
  pending.scheduledRaceSimTime = getCareerSimTime() + schedDelaySec
  pending.scheduledRaceReadyWallEpoch = os.time() + schedDelaySec
  pending.raceReadyToastSent = false
  tech.pendingRaceOffer = pending
  tech.currentAction = "race_pending"
  tech.racingCooldownUntilSimTime = nil
  tech.postRaceCooldownReadyWallEpoch = nil
  racingTeamPersistDrivers(businessId)
  topUpRaceOffers(businessId)
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  if ui_message then
    ui_message(
      string.format(
        "Race scheduled for %s. On the offer map, use Scheduled races → Arm & go to jump to the grid.",
        tech.name or "driver"
      ),
      7,
      "Racing Team",
      "info"
    )
  end
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function assignRolledProxyRaceToDriver(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if not businessId or not techId then
    return false
  end
  if not rtState.rtInternal.isCurrentLeagueAtLeast(businessId, 2) then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired then
    return false
  end
  if tech.jobId or tech.pendingRaceOffer then
    return false
  end
  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId or not getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    return false
  end
  if getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) > 0 then
    if ui_message then
      ui_message(
        string.format("%s is still recovering from their last race.", tech.name or "Driver"),
        6,
        "Racing Team",
        "warning"
      )
    end
    return false
  end
  local levelId = getRacingTeamLevelId()
  if levelId == "" then
    return false
  end
  local now = getCareerSimTime()
  local fv = fleetVehicleId and getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  local branchFilter = fv and resolveFleetVehicleSanctionedBranch(businessId, fv)
    or getSanctionedBranchFilterForBusiness(businessId)
  local picked = rollOneRaceOffer(levelId, now, { branchFilter = branchFilter })
  if not picked then
    picked = rollOneRaceOffer(levelId, now)
  end
  if not picked then
    return false
  end
  if not sanctionedOfferMatchesFleetVehicle(businessId, fleetVehicleId, picked) then
    if ui_message then
      ui_message(
        "This fleet car's hp/kg is outside this race's sanctioned class. Auto-assign skipped this offer.",
        8,
        "Racing Team",
        "warning"
      )
    end
    return false
  end
  if not racingTeamFinances.tryDebitRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId)) then
    if ui_message then
      ui_message("Not enough funds in the team account for the race entry fee.", 6, "Racing Team", "warning")
    end
    return false
  end
  local srHp2 = gameplay_events_freContracts_sanctionedRacing
  if srHp2 and type(srHp2.attachSanctionedOfferDisplayHp) == "function" then
    srHp2.attachSanctionedOfferDisplayHp(picked)
  end
  local pending = {}
  for k, v in pairs(picked) do
    pending[k] = v
  end
  local schedDelaySec = math.random(rtState.K.SCHEDULED_RACE_MIN_SEC, rtState.K.SCHEDULED_RACE_MAX_SEC)
  pending.scheduledRaceSimTime = getCareerSimTime() + schedDelaySec
  pending.scheduledRaceReadyWallEpoch = os.time() + schedDelaySec
  pending.raceReadyToastSent = false
  tech.pendingRaceOffer = pending
  tech.currentAction = "race_pending"
  tech.racingCooldownUntilSimTime = nil
  tech.postRaceCooldownReadyWallEpoch = nil
  racingTeamPersistDrivers(businessId)
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  if ui_message then
    local lvInf = getRacingTeamLevelInfo(levelId)
    ui_message(
      string.format(
        "Proxy race scheduled for %s. Use Scheduled races, then Arm & go.",
        tech.name or "driver"
      ),
      7,
      lvInf.msgProxyRaceScheduledToastTitle,
      "info"
    )
  end
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function listLeague1FleetVehiclesForSanctionedOffer(businessId, offerId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or offerId == nil then
    return {}
  end
  if rtState.rtInternal.getCurrentLeague(businessId) ~= "league1" then
    return {}
  end
  local board = getRaceOfferBoard(businessId)
  local want = tostring(offerId)
  local picked = nil
  for _, o in ipairs(board.offers or {}) do
    if o and tostring(o.id) == want then
      picked = o
      break
    end
  end
  if not picked then
    return {}
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessVehicles then
    return {}
  end
  local vehicles = inv.getBusinessVehicles(businessId) or {}
  local out = {}
  for _, vehicle in ipairs(vehicles) do
    local vid = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId)
    if vid ~= nil then
      local overpowered = fleetVehicleOverpoweredForOffer(businessId, vid, picked)
      local cooldownSec = getFleetVehiclePostRaceCooldownRemainingSec(businessId, vid) or 0
      local onCooldown = cooldownSec > 0
      local formatted = rtState.formatVehicleForUI(vehicle, businessId)
      if formatted then
        table.insert(out, {
          vehicleId = formatted.vehicleId,
          vehicleName = formatted.vehicleName,
          fleetEffectiveHp = formatted.fleetEffectiveHp,
          fleetEffectivePw = formatted.fleetEffectivePw,
          fleetSanctionedClassLabel = formatted.fleetSanctionedClassLabel,
          fleetClassStatusMessage = formatted.fleetClassStatusMessage,
          dynoStatus = formatted.dynoStatus,
          overpowered = overpowered,
          onCooldown = onCooldown,
          cooldownSec = cooldownSec
        })
      else
        table.insert(out, {
          vehicleId = vid,
          vehicleName = "Vehicle " .. tostring(vid),
          dynoStatus = getVehicleDynoStatus(businessId, vid),
          overpowered = overpowered,
          onCooldown = onCooldown,
          cooldownSec = cooldownSec
        })
      end
    end
  end
  return out
end

local function acceptRacingTeamRaceOfferAsPlayer(businessId, offerId, fleetVehicleIdOpt)
  businessId = normalizeBusinessId(businessId)
  if not businessId or offerId == nil then
    return "missing_args"
  end
  if rtState.rtInternal.getCurrentLeague(businessId) ~= "league1" then
    if ui_message then
      ui_message("League 1 (sanctioned board) is required to race from this screen.", 8, "Racing Team", "warning")
    end
    return "wrong_league"
  end
  local fleetVehicleId = nil
  if fleetVehicleIdOpt ~= nil and fleetVehicleIdOpt ~= "" then
    fleetVehicleId = tonumber(fleetVehicleIdOpt) or fleetVehicleIdOpt
  else
    fleetVehicleId = racingTeamGoals.getPrimaryLeaderboardVehicleId(businessId)
  end
  if not fleetVehicleId or not getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    if ui_message then
      ui_message("No valid fleet vehicle selected (inventory id missing or not found).", 8, "Racing Team", "warning")
    end
    return "bad_fleet_vehicle"
  end
  local board = getRaceOfferBoard(businessId)
  local want = tostring(offerId)
  local idx = nil
  local picked = nil
  for i, o in ipairs(board.offers or {}) do
    if o and tostring(o.id) == want then
      idx = i
      picked = o
      break
    end
  end
  if not idx or not picked then
    if ui_message then
      ui_message("That race offer is no longer on the board (refresh or pick another offer).", 8, "Racing Team", "warning")
    end
    return "offer_not_on_board"
  end
  if showDynoRequiredMessageIfBlocked(businessId, fleetVehicleId, picked) then
    return "dyno_required"
  end
  if fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, picked) then
    if guihooks then
      guihooks.trigger("racingTeam:vehicleOutOfClass", { businessId = tostring(businessId) })
    end
    return "out_of_class"
  end
  if not fleetVehicleEligibleForOffer(businessId, fleetVehicleId, picked) then
    local rawEl = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
    local pwEl = rawEl and getEffectiveTeamJobVehiclePw(businessId, rawEl)
    if not pwEl then
      if ui_message then
        ui_message(
          "Cannot read this fleet car's power-to-weight (dyno HP or curb weight missing). Try a dyno pull or another car.",
          10,
          "Racing Team",
          "warning"
        )
      end
      return "fleet_power_weight_unknown"
    end
    if ui_message then
      ui_message("This fleet car is outside the race's power-to-weight bracket.", 8, "Racing Team", "warning")
    end
    return "not_eligible_pw"
  end
  if getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId) > 0 then
    if guihooks then
      guihooks.trigger("racingTeam:vehicleOnCooldown", {
        businessId = tostring(businessId),
        vehicleId = tostring(fleetVehicleId),
        remainingSec = getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId),
      })
    end
    return "vehicle_cooldown"
  end
  if not racingTeamFinances.tryDebitRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId)) then
    if ui_message then
      ui_message("Not enough funds in the team account for the race entry fee.", 6, "Racing Team", "warning")
    end
    return "insufficient_funds"
  end
  table.remove(board.offers, idx)
  local pr = {}
  for k, v in pairs(picked) do
    pr[k] = v
  end
  pr.scheduledRaceSimTime = nil
  pr.scheduledRaceReadyWallEpoch = nil
  pr.disciplineId = pr.disciplineId or "roadracing"
  pr.league1PlayerRace = true
  pr.racingTeamBusinessOffer = true
  pr.businessId = tostring(normalizeBusinessId(businessId))
  pr.fleetVehicleId = tonumber(fleetVehicleId) or fleetVehicleId
  pr.requiredFleetVehicleId = tonumber(fleetVehicleId) or fleetVehicleId
  local sr = gameplay_events_freContracts_sanctionedRacing
  if not sr or not sr.commitAndNavigateExternalOffer then
    racingTeamFinances.refundRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId))
    table.insert(board.offers, idx, picked)
    log("W", "racingTeam", "commitAndNavigateExternalOffer missing; restored offer " .. tostring(want))
    if ui_message then
      ui_message("Sanctioned racing module is not loaded. Restart or check the mod install.", 9, "Racing Team", "error")
    end
    return "sanctioned_module_missing"
  end
  local ok = false
  local commitFailReason = nil
  do
    local started, failMsg = sr.commitAndNavigateExternalOffer(pr, { bypassSkillGate = true })
    ok = started == true
    commitFailReason = failMsg
    if not ok then
      log("W", "racingTeam", "commitAndNavigateExternalOffer returned false for offer " .. tostring(want) .. " err=" .. tostring(failMsg))
    end
  end
  if not ok then
    racingTeamFinances.refundRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId))
    table.insert(board.offers, idx, picked)
    if ui_message and type(commitFailReason) == "string" and commitFailReason ~= "" then
      ui_message(commitFailReason, 10, "Racing Team", "warning")
    elseif ui_message then
      ui_message("Could not start sanctioned race (see beamng.log). Offer was restored.", 9, "Racing Team", "warning")
    end
    return type(commitFailReason) == "string" and commitFailReason ~= "" and commitFailReason or "sanctioned_commit_failed"
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
  topUpRaceOffers(businessId)
  if career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
      end
  return true
end

-- Mirrors listLeague1FleetVehiclesForSanctionedOffer but for league 2+ player
-- races. Same row shape so the existing fleet-picker UI can be reused. The
-- league gate is inverted (league 1 has its own listing path).
local function listLeague2FleetVehiclesForSanctionedOffer(businessId, offerId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or offerId == nil then
    return {}
  end
  if rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    return {}
  end
  local board = getRaceOfferBoard(businessId)
  local want = tostring(offerId)
  local picked = nil
  for _, o in ipairs(board.offers or {}) do
    if o and tostring(o.id) == want then
      picked = o
      break
    end
  end
  if not picked then
    return {}
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessVehicles then
    return {}
  end
  local vehicles = inv.getBusinessVehicles(businessId) or {}
  local playerCooldownSec = getPlayerPostRaceCooldownRemainingSec(businessId) or 0
  local playerOnCooldown = playerCooldownSec > 0
  local out = {}
  for _, vehicle in ipairs(vehicles) do
    local vid = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId)
    if vid ~= nil then
      local overpowered = fleetVehicleOverpoweredForOffer(businessId, vid, picked)
      local cooldownSec = getFleetVehiclePostRaceCooldownRemainingSec(businessId, vid) or 0
      local onCooldown = cooldownSec > 0
      local formatted = rtState.formatVehicleForUI(vehicle, businessId)
      if formatted then
        table.insert(out, {
          vehicleId = formatted.vehicleId,
          vehicleName = formatted.vehicleName,
          fleetEffectiveHp = formatted.fleetEffectiveHp,
          fleetEffectivePw = formatted.fleetEffectivePw,
          fleetSanctionedClassLabel = formatted.fleetSanctionedClassLabel,
          fleetClassStatusMessage = formatted.fleetClassStatusMessage,
          dynoStatus = formatted.dynoStatus,
          overpowered = overpowered,
          onCooldown = onCooldown,
          cooldownSec = cooldownSec,
          playerOnCooldown = playerOnCooldown,
          playerCooldownSec = playerCooldownSec,
        })
      else
        table.insert(out, {
          vehicleId = vid,
          vehicleName = "Vehicle " .. tostring(vid),
          dynoStatus = getVehicleDynoStatus(businessId, vid),
          overpowered = overpowered,
          onCooldown = onCooldown,
          cooldownSec = cooldownSec,
          playerOnCooldown = playerOnCooldown,
          playerCooldownSec = playerCooldownSec,
        })
      end
    end
  end
  return out
end

-- League-2+ "player races alongside proxy". The player drives a team fleet
-- vehicle in real time on a sanctioned offer the team would otherwise have
-- dispatched a driver to. Distinct from acceptRacingTeamRaceOfferAsPlayer
-- (league 1 only) so league 1 gameplay is untouched. The offer gets a
-- `playerProxyAlongsideRace = true` flag which gates the reduced (25%) team
-- payout and the player-specific post-race cooldown.
local function acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(businessId, offerId, fleetVehicleIdOpt)
  businessId = normalizeBusinessId(businessId)
  if not businessId or offerId == nil then
    return "missing_args"
  end
  if rtState.rtInternal.getCurrentLeague(businessId) == "league1" then
    if ui_message then
      ui_message("Use the league 1 board for player races at this level.", 8, "Racing Team", "warning")
    end
    return "wrong_league"
  end
  local fleetVehicleId = nil
  if fleetVehicleIdOpt ~= nil and fleetVehicleIdOpt ~= "" then
    fleetVehicleId = tonumber(fleetVehicleIdOpt) or fleetVehicleIdOpt
  else
    fleetVehicleId = racingTeamGoals.getPrimaryLeaderboardVehicleId(businessId)
  end
  if not fleetVehicleId or not getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    if ui_message then
      ui_message("No valid fleet vehicle selected (inventory id missing or not found).", 8, "Racing Team", "warning")
    end
    return "bad_fleet_vehicle"
  end
  local board = getRaceOfferBoard(businessId)
  local want = tostring(offerId)
  local idx = nil
  local picked = nil
  for i, o in ipairs(board.offers or {}) do
    if o and tostring(o.id) == want then
      idx = i
      picked = o
      break
    end
  end
  if not idx or not picked then
    if ui_message then
      ui_message("That race offer is no longer on the board (refresh or pick another offer).", 8, "Racing Team", "warning")
    end
    return "offer_not_on_board"
  end
  if showDynoRequiredMessageIfBlocked(businessId, fleetVehicleId, picked) then
    return "dyno_required"
  end
  if fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, picked) then
    if guihooks then
      guihooks.trigger("racingTeam:vehicleOutOfClass", { businessId = tostring(businessId) })
    end
    return "out_of_class"
  end
  if not fleetVehicleEligibleForOffer(businessId, fleetVehicleId, picked) then
    local rawEl = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
    local pwEl = rawEl and getEffectiveTeamJobVehiclePw(businessId, rawEl)
    if not pwEl then
      if ui_message then
        ui_message(
          "Cannot read this fleet car's power-to-weight (dyno HP or curb weight missing). Try a dyno pull or another car.",
          10,
          "Racing Team",
          "warning"
        )
      end
      return "fleet_power_weight_unknown"
    end
    if ui_message then
      ui_message("This fleet car is outside the race's power-to-weight bracket.", 8, "Racing Team", "warning")
    end
    return "not_eligible_pw"
  end
  if getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId) > 0 then
    if guihooks then
      guihooks.trigger("racingTeam:vehicleOnCooldown", {
        businessId = tostring(businessId),
        vehicleId = tostring(fleetVehicleId),
        remainingSec = getFleetVehiclePostRaceCooldownRemainingSec(businessId, fleetVehicleId),
      })
    end
    return "vehicle_cooldown"
  end
  local playerCdRem = getPlayerPostRaceCooldownRemainingSec(businessId) or 0
  if playerCdRem > 0 then
    if guihooks then
      guihooks.trigger("racingTeam:playerOnCooldown", {
        businessId = tostring(businessId),
        remainingSec = playerCdRem,
      })
    end
    if ui_message then
      ui_message(
        string.format("You're still recovering from your last race (%d min left).", math.ceil(playerCdRem / 60)),
        7,
        "Racing Team",
        "warning"
      )
    end
    return "player_cooldown"
  end
  if not racingTeamFinances.tryDebitRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId)) then
    if ui_message then
      ui_message("Not enough funds in the team account for the race entry fee.", 6, "Racing Team", "warning")
    end
    return "insufficient_funds"
  end
  table.remove(board.offers, idx)
  local pr = {}
  for k, v in pairs(picked) do
    pr[k] = v
  end
  pr.scheduledRaceSimTime = nil
  pr.scheduledRaceReadyWallEpoch = nil
  pr.disciplineId = pr.disciplineId or "roadracing"
  pr.playerProxyAlongsideRace = true
  pr.racingTeamBusinessOffer = true
  pr.businessId = tostring(normalizeBusinessId(businessId))
  pr.fleetVehicleId = tonumber(fleetVehicleId) or fleetVehicleId
  pr.requiredFleetVehicleId = tonumber(fleetVehicleId) or fleetVehicleId
  local sr = gameplay_events_freContracts_sanctionedRacing
  if not sr or not sr.commitAndNavigateExternalOffer then
    racingTeamFinances.refundRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId))
    table.insert(board.offers, idx, picked)
    log("W", "racingTeam", "commitAndNavigateExternalOffer missing; restored offer " .. tostring(want))
    if ui_message then
      ui_message("Sanctioned racing module is not loaded. Restart or check the mod install.", 9, "Racing Team", "error")
    end
    return "sanctioned_module_missing"
  end
  local started, failMsg = sr.commitAndNavigateExternalOffer(pr, { bypassSkillGate = true })
  local ok = started == true
  if not ok then
    log("W", "racingTeam", "commitAndNavigateExternalOffer returned false for offer " .. tostring(want) .. " err=" .. tostring(failMsg))
    racingTeamFinances.refundRaceEntranceFee(businessId, picked, rtState.rtInternal.getCurrentLeague(businessId))
    table.insert(board.offers, idx, picked)
    if ui_message and type(failMsg) == "string" and failMsg ~= "" then
      ui_message(failMsg, 10, "Racing Team", "warning")
    elseif ui_message then
      ui_message("Could not start sanctioned race (see beamng.log). Offer was restored.", 9, "Racing Team", "warning")
    end
    return type(failMsg) == "string" and failMsg ~= "" and failMsg or "sanctioned_commit_failed"
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
  topUpRaceOffers(businessId)
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

local function declineRacingTeamRaceOffer(businessId, offerId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or offerId == nil then
    return false
  end
  ensureRaceOfferBoard(businessId)
  local board = getRaceOfferBoard(businessId)
  local want = tostring(offerId)
  local idx = nil
  for i, o in ipairs(board.offers or {}) do
    if o and tostring(o.id) == want then
      idx = i
      break
    end
  end
  if not idx then
    return false
  end
  table.remove(board.offers, idx)
  topUpRaceOffers(businessId)
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

local function isScheduledRaceReadyForDriver(businessId, techId)
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or not tech.pendingRaceOffer then
    return true
  end
  local pr = tech.pendingRaceOffer
  local wallDue = tonumber(pr.scheduledRaceReadyWallEpoch)
  if wallDue and os.time() >= wallDue then
    return true
  end
  local t = tonumber(pr.scheduledRaceSimTime)
  if not t then
    return true
  end
  return getCareerSimTime() >= t
end

-- Routes through the phone OS dispatcher so the player's Notifications toggle
-- (Settings -> Notifications -> Racing Team -> Race Ready) is always respected.
local function getPhoneLayout()
  if not ui_phone_layout and extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  return ui_phone_layout
end

local function notifyScheduledRaceReadyIfDue(businessId, tech)
  if not tech then
    return false
  end
  local pending = tech.pendingRaceOffer
  if not pending or pending.raceReadyToastSent then
    return false
  end
  local simDue = tonumber(pending.scheduledRaceSimTime)
  local wallDue = tonumber(pending.scheduledRaceReadyWallEpoch)
  local simReady = not simDue or getCareerSimTime() >= simDue
  local wallReady = wallDue and os.time() >= wallDue
  if not simReady and not wallReady then
    return false
  end
  pending.raceReadyToastSent = true
  local driverName = tech.name or string.format("Driver %s", tostring(tech.id or ""))
  local raceLabel = pending.raceLabel or pending.raceName or "the scheduled race"
  local shopAppLevel = 0
  if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.getNodeProgress then
    shopAppLevel = math.floor(tonumber(career_modules_business_businessSkillTree.getNodeProgress(businessId, "team-operations", "shop-app")) or 0)
  end
  local layout = getPhoneLayout()
  if shopAppLevel > 0 and layout and layout.fireNotification then
    layout.fireNotification("racingTeam.raceReady", {
      title = "Race Ready",
      message = raceLabel,
      kind = "racing",
      ttl = 10,
      meta = driverName,
      source = "Racing Team",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
    })
  elseif ui_message then
    pcall(ui_message, string.format("Team race ready for %s: %s.", driverName, raceLabel), 8, "Racing Team", "info")
  end
  return true
end

local function processScheduledRaceReadyToastQueue()
  if not career_modules_business_businessManager or not career_modules_business_businessManager.getPurchasedBusinesses then
    return
  end
  local purchased = career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType)
  if not purchased then
    return
  end
  for bid, _ in pairs(purchased) do
    local businessId = normalizeBusinessId(bid)
    local changed = false
    for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if notifyScheduledRaceReadyIfDue(businessId, tech) then
        changed = true
      end
    end
    if changed then
      racingTeamPersistDrivers(businessId)
      notifyRacingTeamDriversUpdated(businessId)
    end
  end
end

function M.proxyDriverRaceValidateAndBuildRequest(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local businessId = normalizeBusinessId(opts.businessId)
  local driverId = tonumber(opts.driverId)
  if not businessId or not driverId then
    return { ok = false, err = "missing_business_or_driver" }
  end
  getOfferState(businessId)
  local tech = getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then
    return { ok = false, err = "invalid_driver" }
  end
  if not tech.pendingRaceOffer then
    return { ok = false, err = "no_pending_race_offer" }
  end
  if not isScheduledRaceReadyForDriver(businessId, driverId) then
    return { ok = false, err = "race_not_scheduled_yet" }
  end
  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId or not getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId) then
    return { ok = false, err = "no_valid_fleet_vehicle" }
  end
  local pr = tech.pendingRaceOffer
  if isOfferBlockedByDyno(businessId, fleetVehicleId, pr) then
    return { ok = false, err = "dyno_required" }
  end
  if fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, pr) then
    return { ok = false, err = "fleet_hp_over_class_max" }
  end
  if not fleetVehicleEligibleForOffer(businessId, fleetVehicleId, pr) then
    return { ok = false, err = "fleet_hp_bracket_mismatch" }
  end
  local board = getRaceOfferBoard(businessId)
  local levelId = (board and board.levelId) or getRacingTeamLevelId() or ""
  local offerSnapshot = {}
  for k, v in pairs(pr) do
    offerSnapshot[k] = v
  end
  local id = tostring(normalizeBusinessId(businessId))
  local out = {
    racingTeamProxyRace = true,
    businessId = id,
    driverId = driverId,
    fleetVehicleId = tonumber(fleetVehicleId) or fleetVehicleId,
    offerId = pr.id,
    offerSnapshot = offerSnapshot,
    levelId = levelId,
    raceName = pr.raceName,
    raceLabel = pr.raceLabel,
    raceRouteType = pr.raceRouteType,
    lapCount = tonumber(pr.lapCount),
    stageNumber = tonumber(pr.stageNumber),
    hpBracketLabel = pr.hpBracketLabel,
    requestedAtSimTime = getCareerSimTime(),
  }
  return { ok = true, businessId = businessId, request = out }
end

function M.persistRacingTeamBusinessJson(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    getOfferState(businessId)
    saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

local function clearProxyDriverRaceRequest(businessId)
  local flow = raceFlowMod()
  if flow and flow.clearProxyDriverRaceRequest then
    flow.clearProxyDriverRaceRequest(businessId)
  end
end

local function getProxyDriverRaceRequest(businessId)
  local flow = raceFlowMod()
  return flow and flow.getProxyDriverRaceRequest and flow.getProxyDriverRaceRequest(businessId)
end

function M.isProxyScheduledDriverFleetOverpowered(businessId, driverId)
  businessId = normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return { overpowered = false }
  end
  local tech = getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired or type(tech.pendingRaceOffer) ~= "table" then
    return { overpowered = false }
  end
  if tech.fleetVehicleId == nil then
    return { overpowered = false }
  end
  local pr = tech.pendingRaceOffer
  local fid = tonumber(tech.fleetVehicleId) or tech.fleetVehicleId
  if fleetVehicleOverpoweredForOffer(businessId, fid, pr) then
    return { overpowered = true }
  end
  return { overpowered = false }
end

function M.isArmedProxyFleetOverpoweredForRequest(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { overpowered = false }
  end
  local req = getProxyDriverRaceRequest(businessId)
  local offer = req and type(req.offerSnapshot) == "table" and req.offerSnapshot
  if not offer or not req or req.fleetVehicleId == nil then
    return { overpowered = false }
  end
  local fid = tonumber(req.fleetVehicleId) or req.fleetVehicleId
  if fleetVehicleOverpoweredForOffer(businessId, fid, offer) then
    return { overpowered = true }
  end
  return { overpowered = false }
end

local function getRacingTeamBusinessSkillXpValue(businessId)
  getOfferState(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return math.max(0, math.floor(tonumber(rtState.businessSkillXpByBusiness[id]) or 0))
end

local function addRacingTeamBusinessSkillXpValue(businessId, amount)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not amount or amount <= 0 then
    return
  end
  getOfferState(businessId)
  local id = tostring(businessId)
  local cur = math.max(0, math.floor(tonumber(rtState.businessSkillXpByBusiness[id]) or 0))
  rtState.businessSkillXpByBusiness[id] = cur + math.floor(amount)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
end

local function spendRacingTeamBusinessSkillXpValue(businessId, amount)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not amount or amount <= 0 then
    return false
  end
  getOfferState(businessId)
  local id = tostring(businessId)
  local cur = math.max(0, math.floor(tonumber(rtState.businessSkillXpByBusiness[id]) or 0))
  local need = math.floor(amount)
  if cur < need then
    return false
  end
  rtState.businessSkillXpByBusiness[id] = cur - need
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
  return true
end

local function racingDriverSkillClassLabel(xp)
  local x = math.max(0, math.floor(tonumber(xp) or 0))
  if x >= 8000 then
    return "Elite"
  end
  if x >= 4000 then
    return "Veteran"
  end
  if x >= 1500 then
    return "Established"
  end
  if x >= 400 then
    return "Developing"
  end
  return "Rookie"
end

local function proxyDriverAiDifficultyBlendTFromXp(xp)
  local x = math.max(0, math.floor(tonumber(xp) or 0))
  if x >= 8000 then
    return 1
  end
  if x >= 4000 then
    return 0.75
  end
  if x >= 1500 then
    return 0.5
  end
  if x >= 400 then
    return 0.25
  end
  return 0
end

function M.getProxyDriverAiDifficultyBlendT(businessId, driverId)
  businessId = normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return 1
  end
  getOfferState(businessId)
  local tech = getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then
    return 1
  end
  return proxyDriverAiDifficultyBlendTFromXp(tech.racingSkillXp)
end

local function applyProxySanctionedRaceDriverStats(businessId, driverId, place, options)
  businessId = normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  place = tonumber(place)
  if not businessId or not driverId or not place then
    return
  end
  options = options or {}
  local eligiblePodium = options.eligiblePodium == true
  local xpGain = math.max(0, math.floor(tonumber(options.xpGain) or 0))
  local tech = getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then
    return
  end
  ensureRacingDriverIdentity(tech, tech.id)
  tech.sanctionedRacesFinished = tech.sanctionedRacesFinished + 1
  if eligiblePodium and place >= 1 and place <= 3 then
    tech.sanctionedPodiums = tech.sanctionedPodiums + 1
    if place == 1 then
      tech.sanctionedRaceWins = tech.sanctionedRaceWins + 1
    end
  end
  if xpGain > 0 then
    tech.racingSkillXp = tech.racingSkillXp + xpGain
  end
  racingTeamPersistDrivers(businessId)
  notifyRacingTeamDriversUpdated(businessId)
  if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
    rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  end
end

local function settleProxySanctionedRaceFromAiResults(businessId, aiResults)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { money = 0, businessSkillXp = 0, noRewardDetail = "Invalid business." }
  end
  getOfferState(businessId)
  local req = getProxyDriverRaceRequest(businessId)
  local offer = req and type(req.offerSnapshot) == "table" and req.offerSnapshot
  if not offer and req and tonumber(req.driverId) then
    local tech = getRacingTeamDriverById(businessId, tonumber(req.driverId))
    offer = tech and tech.pendingRaceOffer
  end
  if not offer then
    return { money = 0, businessSkillXp = 0, noRewardDetail = "No team race offer on file." }
  end
  if not aiResults then
    return { money = 0, businessSkillXp = 0, noRewardDetail = "No race results — no podium reward." }
  end
  local place = nil
  for _, row in ipairs(aiResults) do
    if row.isPlayer then
      place = tonumber(row.place)
      break
    end
  end
  if not place then
    return { money = 0, businessSkillXp = 0, noRewardDetail = "Couldn't determine placement — no podium reward." }
  end
  local driverId = req and tonumber(req.driverId)
  do
    local fleetVid = nil
    if driverId then
      local t = getRacingTeamDriverById(businessId, driverId)
      fleetVid = t and t.fleetVehicleId
    end
    if not fleetVid then
      fleetVid = tonumber(offer.requiredFleetVehicleId) or offer.requiredFleetVehicleId
        or tonumber(offer.fleetVehicleId) or offer.fleetVehicleId
    end
    if fleetVid then
      armFleetVehiclePostRaceCooldown(businessId, fleetVid)
      local _, savePath = career_saveSystem.getCurrentProfile()
      if savePath then
        saveRacingTeamPersistedState(businessId, savePath)
      end
    end
  end
  local podiumHpBandReason = nil
  local hMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hMax = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or hMin
  if hMax < hMin then
    hMin, hMax = hMax, hMin
  end
  if (hMax > 0 or hMin > 0) and career_modules_competitiveRace_aiRacers
      and career_modules_competitiveRace_aiRacers.getPlayerVehiclePwForPodiumCapCheck then
    local pwLive = career_modules_competitiveRace_aiRacers.getPlayerVehiclePwForPodiumCapCheck()
    if type(pwLive) == "number" then
      if pwLive > hMax then
        podiumHpBandReason = "Over class hp/kg limit — no podium rewards."
      elseif pwLive < hMin then
        podiumHpBandReason = "Below class minimum hp/kg — no podium rewards."
      end
    end
  end
  if place >= 1 and place <= 3 then
    if podiumHpBandReason then
      applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = false, xpGain = 0 })
      return { money = 0, businessSkillXp = 0, noRewardDetail = podiumHpBandReason }
    end
    do
      local offerForNotify = offer
      if type(offerForNotify) == "table" then
        offerForNotify = {}
        for k, v in pairs(offer) do
          offerForNotify[k] = v
        end
        offerForNotify.racingTeamBusinessOffer = true
        offerForNotify.businessId = offerForNotify.businessId or businessId
      end
      M.notifyOfficialSanctionedPodium(place, offerForNotify)
    end
    local amount = 0
    local xpStored = nil
    if place == 1 then
      amount = tonumber(offer.payoutFirst) or 0
      xpStored = offer.xpFirst
    elseif place == 2 then
      amount = tonumber(offer.payoutSecond) or 0
      xpStored = offer.xpSecond
    elseif place == 3 then
      amount = tonumber(offer.payoutThird) or 0
      xpStored = offer.xpThird
    end
    amount = math.floor(math.max(0, amount))
    local xpNum = tonumber(xpStored)
    local xpAmount = (xpNum ~= nil) and math.max(0, math.floor(xpNum)) or proxyPodiumXpFromMoney(amount)
    local bm, bx = racingTeamSponsorBonusTotals(businessId)
    amount = math.floor(amount * (1 + bm) + 0.5)
    xpAmount = math.floor(xpAmount * (1 + bx) + 0.5)
    local paLevel = getSkillTreeNodeLevel(businessId, "driver", "podium-analytics")
    if paLevel > 0 then
      xpAmount = math.floor(xpAmount * (1 + 0.1 * paLevel) + 0.5)
    end
    if amount <= 0 then
      applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = true, xpGain = 0 })
      if career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
      end
      return { money = 0, businessSkillXp = 0, noRewardDetail = "No payout configured for this podium position." }
    end
    if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.rewardToAccount then
      applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = true, xpGain = 0 })
      return { money = 0, businessSkillXp = 0, noRewardDetail = "Bank unavailable — reward not applied." }
    end
    local businessAccount = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
    local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
    if not accountId then
      applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = true, xpGain = 0 })
      return { money = 0, businessSkillXp = 0, noRewardDetail = "No business account — reward not applied." }
    end
    
    local techCut = driverId and getRacingTeamDriverById(businessId, driverId)
    local dname = techCut and techCut.name or "Driver"
    local pct = math.floor(racingTeamFinances.driverCutPercentFromRacingXp(techCut and techCut.racingSkillXp or 0) + 0.5)
    local cut = math.floor(amount * pct / 100 + 0.5)
    local netPayout = amount - cut
    local txLabel = string.format("Sanctioned team race (%s) - P%d", dname, place)
    local txDesc = string.format("Circuit payout: +$%d (%d%% net), -$%d (%d%% driver share — %s)", netPayout, 100 - pct, cut, pct, dname)
    
    local ok = career_modules_bank.rewardToAccount({
      money = { amount = amount, canBeNegative = false },
    }, accountId, txLabel, txDesc)
    if not ok then
      applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = true, xpGain = 0 })
      return { money = 0, businessSkillXp = 0, noRewardDetail = "Could not deposit race payout." }
    end
    do
      racingTeamFinances.applyDriverCutAfterPayout(businessId, amount, {
        racingSkillXp = techCut and techCut.racingSkillXp,
        driverName = techCut and techCut.name,
      })
    end
    local uiMessage = string.format("P%d Finish (%s): +$%d (%d%% net, %d%% driver share).", place, dname, netPayout, 100 - pct, pct)
    if ui_message then ui_message(uiMessage, 7, "Racing Team", "info") end
    if xpAmount > 0 then
      addRacingTeamBusinessSkillXpValue(businessId, xpAmount)
    end
    applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = true, xpGain = xpAmount })
    if career_saveSystem.saveCurrent then
      career_saveSystem.saveCurrent()
    end
    return { money = amount, businessSkillXp = xpAmount, noRewardDetail = nil }
  end
  applyProxySanctionedRaceDriverStats(businessId, driverId, place, { eligiblePodium = false, xpGain = 0 })
  return { money = 0, businessSkillXp = 0, noRewardDetail = "Didn't place on the podium — no podium rewards." }
end

local function onBusinessSanctionedRaceOutcome(offer, place, reason)
  if type(offer) ~= "table" or offer.racingTeamBusinessOffer ~= true then
    return
  end
  local businessId = normalizeBusinessId(offer.businessId)
  if not businessId then
    return
  end
  if rtState.rtInternal.getCurrentLeague(businessId) ~= "league1" then
    return
  end
  getOfferState(businessId)
  local p = tonumber(place)
  if p == 1 then
    local old = getPendingRematchOffer(businessId)
    if type(old) == "table" and old.id then
      local board = getRaceOfferBoard(businessId)
      removeOfferById(board, old.id)
    end
    setPendingRematchOffer(businessId, nil)
    return
  end
  local lineup = normalizeLineupSnapshot(offer.rematchAiLineupSnapshot)
  local capHp = lineupMaxPw(lineup, offer.classPwMax or offer.classHpMax)
  local rematchId = string.format("rt-rematch-%s-%d", tostring(businessId), math.floor(getCareerSimTime() * 1000))
  local rematch = {
    id = rematchId,
    disciplineId = offer.disciplineId or "roadracing",
    raceName = offer.raceName,
    raceLabel = (offer.raceLabel or offer.raceName or "Race") .. " - Rematch",
    stageNumber = tonumber(offer.stageNumber) or 1,
    raceRouteType = offer.raceRouteType,
    hpBracketId = offer.hpBracketId,
    hpBracketBranch = offer.hpBracketBranch,
    hpBracketLabel = offer.hpBracketLabel,
    hpBracketPayoutMult = offer.hpBracketPayoutMult,
    classPwMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0,
    classPwMax = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    classHpMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0,
    classHpMax = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    lapCount = tonumber(offer.lapCount) or 3,
    payoutFirst = offer.payoutFirst,
    payoutSecond = offer.payoutSecond,
    payoutThird = offer.payoutThird,
    xpFirst = offer.xpFirst,
    xpSecond = offer.xpSecond,
    xpThird = offer.xpThird,
    startDeadlineMinutes = tonumber(offer.startDeadlineMinutes) or 60,
    phase = "available",
    isRematch = true,
    rematchReason = type(reason) == "string" and reason or "non_win",
    rematchSourceOfferId = offer.id,
    requiredFleetVehicleId = tonumber(offer.requiredFleetVehicleId) or offer.requiredFleetVehicleId,
    rematchMaxAiPw = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    rematchMaxAiHp = tonumber(capHp) or tonumber(offer.classPwMax) or tonumber(offer.classHpMax),
    rematchAiLineupSnapshot = lineup,
  }
  local srRem = gameplay_events_freContracts_sanctionedRacing
  if srRem and type(srRem.attachSanctionedOfferDisplayHp) == "function" then
    srRem.attachSanctionedOfferDisplayHp(rematch)
  end
  setPendingRematchOffer(businessId, rematch)
  local board = getRaceOfferBoard(businessId)
  removeOfferById(board, rematch.id)
  table.insert(board.offers, 1, rematch)
  while #board.offers > getMaxRaceOffersOnBoard(businessId) do
    table.remove(board.offers, #board.offers)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

local function findProxyDriverRaceRequestForLevel(levelId)
  local flow = raceFlowMod()
  if flow and flow.findProxyDriverRaceRequestForLevel then
    return flow.findProxyDriverRaceRequestForLevel(levelId)
  end
  return nil, nil
end

local function formatRacingTeamDriverForUI(businessId, tech)
  if not tech then
    return nil
  end
  ensureRacingDriverIdentity(tech, tech.id)
  local postRaceCd = getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech)
  local job = nil
  if tech.jobId then
    job = getRacingTeamActiveJobByJobId(businessId, tech.jobId)
  end
  local label = "Idle"
  if tech.pendingRaceOffer then
    local pr = tech.pendingRaceOffer
    label = string.format("Sanctioned race: %s", pr.raceLabel or pr.raceName or "Race")
  elseif tech.jobId and job then
    label = job.vehicleName and string.format("Assigned: %s", job.vehicleName) or "Assigned to job"
  elseif tech.jobId then
    label = "Assigned"
  elseif postRaceCd > 0 then
    label = string.format("Cooldown (~%dm)", math.max(1, math.ceil(postRaceCd / 60)))
  end
  local jobLabel = job and (job.raceLabel or job.vehicleName) or nil
  local jobReward = job and tonumber(job.reward) or nil
  local scheduledRaceSimTime = nil
  local scheduledRaceReadyWallEpoch = nil
  local secondsUntilScheduledRace = nil
  local scheduledRaceReady = true
  if tech.pendingRaceOffer then
    local pr = tech.pendingRaceOffer
    scheduledRaceSimTime = tonumber(pr.scheduledRaceSimTime)
    scheduledRaceReadyWallEpoch = tonumber(pr.scheduledRaceReadyWallEpoch)
    local nowSim = getCareerSimTime()
    local simRem = nil
    if scheduledRaceSimTime then
      simRem = math.max(0, scheduledRaceSimTime - nowSim)
      scheduledRaceReady = nowSim >= scheduledRaceSimTime
    end
    local wallRem = nil
    if scheduledRaceReadyWallEpoch then
      wallRem = math.max(0, scheduledRaceReadyWallEpoch - os.time())
      if wallRem <= 0 then
        scheduledRaceReady = true
      end
    end
    if simRem and wallRem then
      secondsUntilScheduledRace = math.min(simRem, wallRem)
    elseif wallRem then
      secondsUntilScheduledRace = wallRem
      scheduledRaceReady = wallRem <= 0 or scheduledRaceReady
    elseif simRem then
      secondsUntilScheduledRace = simRem
    end
  end
  local fleetVehicleId = tech.fleetVehicleId
  local fleetVehicleName = nil
  if fleetVehicleId then
    local rawV = getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
    if rawV then
      local modelKey = rawV.vehicleConfig and rawV.vehicleConfig.model_key or nil
      fleetVehicleName = modelKey or ("Vehicle " .. tostring(tonumber(rawV.vehicleId) or rawV.vehicleId))
    else
      fleetVehicleName = "Unavailable"
    end
  end
  
  local simState = racingTeamRaceSim and racingTeamRaceSim.getDriverSimState and racingTeamRaceSim.getDriverSimState(businessId, tech.id)
  local isInSim = simState ~= nil
  return {
    id = tech.id,
    name = tech.name,
    state = tech.state or 0,
    action = simState and simState.phase or tech.currentAction or "idle",
    label = simState and simState.badge or label,
    progress = simState and simState.progress or 0,
    elapsedSeconds = simState and simState.stateElapsed or 0,
    totalSeconds = simState and simState.stateDuration or 0,
    isInSim = isInSim,
    canSpectate = simState and simState.canSpectate == true or false,
    simBadge = simState and simState.badge or nil,
    simPhase = simState and simState.phase or nil,
    serverTime = os.clock(),
    jobId = tech.jobId,
    jobLabel = jobLabel,
    jobReward = jobReward,
    fleetVehicleId = fleetVehicleId,
    fleetVehicleName = fleetVehicleName,
    dynoStatus = getVehicleDynoStatus(businessId, fleetVehicleId),
    pendingRaceOffer = tech.pendingRaceOffer,
    scheduledRaceSimTime = scheduledRaceSimTime,
    scheduledRaceReadyWallEpoch = scheduledRaceReadyWallEpoch,
    secondsUntilScheduledRace = secondsUntilScheduledRace,
    scheduledRaceReady = scheduledRaceReady,
    canAssign = not tech.fired
      and not tech.jobId
      and not tech.pendingRaceOffer
      and (tech.currentAction == "idle")
      and postRaceCd <= 0
      and not isInSim,
    postRaceCooldownRemainingSec = postRaceCd,
    racingCooldownUntilSimTime = tonumber(tech.racingCooldownUntilSimTime),
    postRaceCooldownReadyWallEpoch = tonumber(tech.postRaceCooldownReadyWallEpoch),
    fired = tech.fired or false,
    successfulJobs = tech.successfulJobs or 0,
    failedJobs = tech.failedJobs or 0,
    racingSkillXp = tech.racingSkillXp,
    driverSkillClass = racingDriverSkillClassLabel(tech.racingSkillXp),
    sanctionedRacesFinished = tech.sanctionedRacesFinished,
    sanctionedRaceWins = tech.sanctionedRaceWins,
    sanctionedPodiums = tech.sanctionedPodiums,
  }
end

notifyRacingTeamDriversUpdated = function(businessId)
  if not businessId or getRacingTeamDriverCapacity(businessId) < 1 then
    return
  end
  local techEntries = {}
  for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    local formatted = formatRacingTeamDriverForUI(businessId, tech)
    if formatted then
      table.insert(techEntries, formatted)
    end
  end
  if guihooks then
    guihooks.trigger("businessComputer:onTechsUpdated", {
      businessType = rtState.businessType,
      businessId = tostring(businessId),
      techs = techEntries,
    })
  end
end

racingTeamPersistDrivers = function(businessId)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamDrivers(businessId, savePath)
  end
end

local function pushRaceOfferBackToBoardIfRoom(businessId, offerTable)
  if type(offerTable) ~= "table" then
    return
  end
  if offerTable.id == nil then
    return
  end
  local board = getRaceOfferBoard(businessId)
  board.offers = board.offers or {}
  local want = tostring(offerTable.id)
  for _, o in ipairs(board.offers) do
    if o and tostring(o.id) == want then
      return
    end
  end
  local restored = {}
  for k, v in pairs(offerTable) do
    if k ~= "scheduledRaceSimTime" and k ~= "scheduledRaceReadyWallEpoch" then
      restored[k] = v
    end
  end
  restored.phase = restored.phase or "available"
  table.insert(board.offers, restored)
end

local function clearRacingTeamProxyDriverAssignment(businessId, opts)
  opts = opts or {}
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  getOfferState(businessId)
  local req = opts.proxyRequest
  if type(req) ~= "table" then
    req = getProxyDriverRaceRequest(businessId)
  end
  local driverId = req and tonumber(req.driverId)
  local tech = driverId and getRacingTeamDriverById(businessId, driverId)
  if tech and tech.fired then
    tech = nil
  end
  local explicitDriver = driverId ~= nil
  if not tech and not explicitDriver then
    for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if t and not t.fired and t.pendingRaceOffer and t.currentAction == "race_pending" then
        tech = t
        break
      end
    end
  end
  if not tech or tech.fired then
    return false
  end
  if not tech.pendingRaceOffer then
    return explicitDriver
  end
  local pendingCopy = tech.pendingRaceOffer
  tech.pendingRaceOffer = nil
  tech.currentAction = "idle"
  if not opts.returnOfferToBoard then
    local cdSec = getRacingTeamPostRaceCooldownSeconds(businessId)
    local nowSim = getCareerSimTime()
    tech.racingCooldownUntilSimTime = nowSim + cdSec
    tech.postRaceCooldownReadyWallEpoch = os.time() + cdSec
  end
  racingTeamPersistDrivers(businessId)
  if opts.returnOfferToBoard then
    pushRaceOfferBackToBoardIfRoom(businessId, pendingCopy)
  end
  topUpRaceOffers(businessId)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function cancelUnarmedScheduledRacingTeamProxyRace(businessId, driverId)
  businessId = normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return { ok = false, err = "missing_business_or_driver" }
  end
  local tech = getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired or not tech.pendingRaceOffer then
    return { ok = false, err = "no_pending_race_offer" }
  end
  local pendingCopy = tech.pendingRaceOffer
  tech.pendingRaceOffer = nil
  tech.currentAction = "idle"
  racingTeamPersistDrivers(businessId)
  pushRaceOfferBackToBoardIfRoom(businessId, pendingCopy)
  racingTeamFinances.refundRaceEntranceFee(businessId, pendingCopy, rtState.rtInternal.getCurrentLeague(businessId))
  topUpRaceOffers(businessId)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  notifyRacingTeamDriversUpdated(businessId)
  if guihooks and guihooks.trigger then
    local uid = rtState.rtInternal.getUIData(businessId)
    guihooks.trigger("businessComputer:onRaceOffersUpdated", {
      businessId = businessId,
      raceOffers = uid and uid.raceOffers or {},
      raceOffersLevelId = uid and uid.raceOffersLevelId,
      raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
      raceOffersMessage = uid and uid.raceOffersMessage,
      racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
    })
  end
  return { ok = true }
end

local function clearStuckRacingTeamProxyAfterTrackRaceCompletion()
  if not career_modules_business_businessManager or not career_modules_business_businessManager.getPurchasedBusinesses then
    return
  end
  local purchased = career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType)
  if not purchased then
    return
  end
  for bid, _ in pairs(purchased) do
    local req = getProxyDriverRaceRequest(bid)
    if req and req.racingTeamProxyRace then
      clearRacingTeamProxyDriverAssignment(bid, {
        returnOfferToBoard = false,
        proxyRequest = req,
      })
      clearProxyDriverRaceRequest(bid)
    end
  end
end

local function clearRacingTeamDriverAssignmentForJob(businessId, jobId)
  for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    if tech.jobId and jobIdsMatch(jobId, tech.jobId) then
      tech.jobId = nil
      tech.currentAction = "idle"
    end
  end
  local job = getRacingTeamActiveJobByJobId(businessId, jobId)
  if job then
    job.techAssigned = nil
    job.locked = false
  end
end

syncRacingTeamDriverUnlock = function(businessId)
  rtState.loadRacingTeamDrivers(businessId)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamDrivers(businessId, savePath)
  end
end

local function assignJobToTech(businessId, techId, jobId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  jobId = tonumber(jobId) or jobId
  if getRacingTeamDriverCapacity(businessId) < 1 then
    return false
  end
  if not businessId or not techId or not jobId then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired then
    return false
  end
  if tech.jobId then
    return false
  end
  if tech.pendingRaceOffer then
    return false
  end
  local job = getRacingTeamActiveJobByJobId(businessId, jobId)
  if not job then
    return false
  end
  if job.techAssigned and job.techAssigned ~= techId then
    return false
  end
  for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    if t.id ~= techId and t.jobId and jobIdsMatch(t.jobId, jobId) then
      t.jobId = nil
      t.currentAction = "idle"
    end
  end
  tech.jobId = jobId
  tech.currentAction = "assigned"
  job.techAssigned = techId
  job.locked = true
  racingTeamPersistDrivers(businessId)
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function assignFleetVehicleToDriver(businessId, techId, vehicleId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  vehicleId = tonumber(vehicleId) or vehicleId
  if getRacingTeamDriverCapacity(businessId) < 1 then
    return false
  end
  if not businessId or not techId or not vehicleId then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired then
    return false
  end
  if tech.pendingRaceOffer then
    return false
  end
  if not getBusinessVehicleRawByInventoryId(businessId, vehicleId) then
    return false
  end
  for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    if t.id ~= techId and t.fleetVehicleId and jobIdsMatch(t.fleetVehicleId, vehicleId) then
      t.fleetVehicleId = nil
    end
  end
  tech.fleetVehicleId = tonumber(vehicleId) or vehicleId
  racingTeamPersistDrivers(businessId)
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function updateTechName(businessId, techId, newName)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if getRacingTeamDriverCapacity(businessId) < 1 or not businessId or not techId then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech then
    return false
  end
  if type(newName) == "string" then
    local trimmed = newName:match("^%s*(.-)%s*$")
    if trimmed == "" then
      trimmed = string.format("Driver #%d", techId)
    end
    tech.name = trimmed
    racingTeamPersistDrivers(businessId)
    notifyRacingTeamDriversUpdated(businessId)
    return true
  end
  return false
end

local function fireTech(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if getRacingTeamDriverCapacity(businessId) < 1 or not businessId or not techId then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired then
    return false
  end
  if tech.jobId or tech.pendingRaceOffer then
    return false
  end
  tech.fired = true
  tech.fleetVehicleId = nil
  racingTeamPersistDrivers(businessId)
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function hireTech(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if getRacingTeamDriverCapacity(businessId) < 1 or not businessId or not techId then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or not tech.fired then
    return false
  end
  local hiredCount = 0
  for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
    if not t.fired then
      hiredCount = hiredCount + 1
    end
  end
  if hiredCount >= getRacingTeamDriverCapacity(businessId) then
    return false
  end
  tech.fired = false
  ensureRacingTeamDriverSlots(businessId)
  racingTeamPersistDrivers(businessId)
  notifyRacingTeamDriversUpdated(businessId)
  rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  return true
end

local function stopTechFromJob(businessId, techId)
  businessId = normalizeBusinessId(businessId)
  techId = tonumber(techId)
  if getRacingTeamDriverCapacity(businessId) < 1 or not businessId or not techId then
    return false
  end
  local tech = getRacingTeamDriverById(businessId, techId)
  if not tech or tech.fired or not tech.jobId then
    return false
  end
  local jId = tech.jobId
  tech.jobId = nil
  tech.currentAction = "idle"
  local job = getRacingTeamActiveJobByJobId(businessId, jId)
  if job then
    job.techAssigned = nil
    job.locked = false
  end
  racingTeamPersistDrivers(businessId)
  notifyRacingTeamDriversUpdated(businessId)
  return true
end

local function findActiveVehicleJobByVehicleId(state, vehicleId)
  local vid = tonumber(vehicleId) or vehicleId
  if vid == nil then
    return nil, nil
  end
  for i, activeJob in ipairs(state.active or {}) do
    if activeJob.storedVehicleId ~= nil and (tonumber(activeJob.storedVehicleId) or activeJob.storedVehicleId) == vid then
      return i, activeJob
    end
  end
  return nil, nil
end

rtState.formatVehicleForUI = function(vehicle, businessId)
  if not vehicle then return nil end
  local vehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
  local modelKey = vehicle.vehicleConfig and vehicle.vehicleConfig.model_key or nil
  local configKey = vehicle.vehicleConfig 
    and ( vehicle.vehicleConfig.key or vehicle.vehicleConfig.config_key)
    or nil
  local name, vehicleYear, vehicleType, vehicleImage =
    career_modules_business_businessHelpers.extractDisplayInfo(getCatalogVehicleInfo(modelKey, configKey))
  local vehicleName = name or modelKey or ("Vehicle " .. tostring(vehicleId))
  local spawnedVehicleId = nil
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getSpawnedVehicleId then
    spawnedVehicleId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
  end
  if vehicle.spawnedVehicleId then
    spawnedVehicleId = vehicle.spawnedVehicleId
  end
  local vehicleValue = 0
  local sellValue = 0
  local okVal = pcall(function()
    vehicleValue = getTeamVehicleBookValue(vehicle)
    local _, linkedJob = findActiveVehicleJobByVehicleId(getOfferState(businessId), vehicleId)
    local saleFallback = tonumber(linkedJob and linkedJob.reward) or 0
    sellValue = getTeamVehicleSellValue(vehicle, saleFallback)
  end)
  if not okVal then
    vehicleValue = math.max(0, math.floor(tonumber(vehicle.purchasePrice) or 0))
    sellValue = vehicleValue
  end
  local fleetRepairNeeded = false
  local fleetRepairDeductible = 750
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getFleetInsuranceRepairQuote then
    local fq = career_modules_business_businessInventory.getFleetInsuranceRepairQuote(businessId, vehicleId)
    if fq then
      fleetRepairNeeded = fq.needsRepair == true
      fleetRepairDeductible = math.max(0, math.floor(tonumber(fq.deductible) or 750))
    end
  end
  local hpEff = getEffectiveTeamJobVehicleHp(businessId, vehicle)
  local fleetEffectiveHp = hpEff and math.floor(tonumber(hpEff) + 0.5) or nil
  local pwEff = getEffectiveTeamJobVehiclePw(businessId, vehicle)
  local fleetEffectivePw = nil
  if type(pwEff) == "number" and pwEff > 0 then
    fleetEffectivePw = math.floor(pwEff * 100 + 0.5) / 100
  end
  local fleetSanctionedClassLabel = nil
  local fleetClassStatusMessage = nil
  if type(pwEff) == "number" and pwEff > 0 then
    local srLbl = gameplay_events_freContracts_sanctionedRacing
    if srLbl and srLbl.getSanctionedPwBracketLabelForPw then
      fleetSanctionedClassLabel = srLbl.getSanctionedPwBracketLabelForPw(pwEff)
    end
  end
  local prevSnap = type(vehicle.savedFleetClassUi) == "table" and vehicle.savedFleetClassUi or nil
  if type(fleetEffectivePw) == "number" and fleetEffectivePw > 0 and type(fleetSanctionedClassLabel) == "string" and fleetSanctionedClassLabel ~= "" then
    vehicle.savedFleetClassUi = {
      performancePw = fleetEffectivePw,
      label = fleetSanctionedClassLabel,
    }
  elseif prevSnap then
    if (fleetSanctionedClassLabel == nil or fleetSanctionedClassLabel == "") and type(prevSnap.label) == "string" and prevSnap.label ~= "" then
      fleetSanctionedClassLabel = prevSnap.label
    end
    if (fleetEffectivePw == nil or fleetEffectivePw <= 0) and type(prevSnap.performancePw) == "number" and prevSnap.performancePw > 0 then
      fleetEffectivePw = prevSnap.performancePw
    end
  end
  if (fleetSanctionedClassLabel == nil or fleetSanctionedClassLabel == "")
      and not (type(fleetEffectivePw) == "number" and fleetEffectivePw > 0) then
    fleetClassStatusMessage = "no weight found for config - pull out vehicle or open parts"
  end
  local dynoStatus = getVehicleDynoStatus(businessId, vehicleId)
  local cooldownSec = getFleetVehiclePostRaceCooldownRemainingSec(businessId, vehicleId) or 0
  return {
    id = tostring(vehicleId),
    vehicleId = vehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    storedTime = vehicle.storedTime,
    spawnedVehicleId = spawnedVehicleId,
    model_key = modelKey,
    config_key = configKey,
    vehicleValue = vehicleValue,
    sellValue = sellValue,
    fleetRepairNeeded = fleetRepairNeeded,
    fleetRepairDeductible = fleetRepairDeductible,
    fleetEffectiveHp = fleetEffectiveHp,
    fleetEffectivePw = fleetEffectivePw,
    fleetSanctionedClassLabel = fleetSanctionedClassLabel,
    fleetClassStatusMessage = fleetClassStatusMessage,
    dynoStatus = dynoStatus,
    cooldownSec = cooldownSec,
  }
end

local function getActiveJobs(businessId)
  local state = getOfferState(businessId)
  return state.active or {}
end

local function getNewJobs(businessId)
  local state = getOfferState(businessId)
  return state.new or {}
end

local function acceptJob(businessId, jobId)
  if not businessId or jobId == nil or jobId == false or jobId == "" then
    return false
  end
  if type(jobId) == "number" and jobId == 0 then
    return false
  end

  local state = getOfferState(businessId)

  local maxActive = getMaxActiveJobs(businessId)
  if #(state.active or {}) >= maxActive then
    return false
  end

  local foundIndex = nil
  local job = nil

  for i, offer in ipairs(state.new or {}) do
    if jobIdsMatch(jobId, offer.jobId) then
      foundIndex = i
      job = offer
      break
    end
  end

  if not foundIndex or not job then
    return false
  end

  local vehicleCost = tonumber(job.reward) or 0
  if vehicleCost > 0 then
    if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.payFromAccount then
      return false
    end

    local businessAccount = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
    local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
    if not accountId then
      return false
    end

    local paid = career_modules_bank.payFromAccount({
      money = {
        amount = vehicleCost,
        canBeNegative = false
      }
    }, accountId, "Vehicle Purchase", "Purchased vehicle for racing team")

    if not paid then
      return false
    end
  end

  table.remove(state.new, foundIndex)
  job.status = "active"
  job.acceptedTime = os.time()
  table.insert(state.active, job)

  if job.vehicleConfig and career_modules_business_businessInventory
    and career_modules_business_businessInventory.storeVehicle then
    local okStore, storedVehicleId = career_modules_business_businessInventory.storeVehicle(businessId, {
    vehicleConfig = job.vehicleConfig,
    mileage = job.mileage or 0,
      purchasePrice = vehicleCost,
    storedTime = os.time()
    })
    if okStore and storedVehicleId ~= nil then
      job.storedVehicleId = storedVehicleId
    end
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
    rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  end
  return true
end

local function declineJob(businessId, jobId)
  if not businessId or jobId == nil or jobId == false or jobId == "" then
    return false
  end
  if type(jobId) == "number" and jobId == 0 then
    return false
  end

  local state = getOfferState(businessId)
  
  for i, offer in ipairs(state.new or {}) do
    if jobIdsMatch(jobId, offer.jobId) then
      table.remove(state.new, i)
      if career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
      end
      return true
    end
  end

  return false
end

local function abandonJob(businessId, jobId)
  if not businessId or jobId == nil or jobId == false or jobId == "" then
    return false
  end
  if type(jobId) == "number" and jobId == 0 then
    return false
  end

  local state = getOfferState(businessId)

  local foundIndex = nil
  local job = nil

  for i, activeJob in ipairs(state.active or {}) do
    if jobIdsMatch(jobId, activeJob.jobId) then
      foundIndex = i
      job = activeJob
      break
    end
  end

  if not foundIndex or not job then
    return false
  end

  if not career_modules_business_businessInventory then
    return false
  end
  
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
  local vehicleToRemove = nil
  for _, vehicle in ipairs(vehicles) do
    if job.storedVehicleId ~= nil and tonumber(vehicle.vehicleId) == tonumber(job.storedVehicleId) then
      vehicleToRemove = vehicle
      break
    end
    if job.storedVehicleId == nil and jobIdsMatch(jobId, vehicle.jobId) then
        vehicleToRemove = vehicle
        break
      end
    end
    
    if not vehicleToRemove then
      return false
    end

    local saleFallback = tonumber(job.reward) or 0
    local salePrice = getTeamVehicleSellValue(vehicleToRemove, saleFallback)
    
    if salePrice > 0 then
      if not career_modules_bank
      or not career_modules_bank.getBusinessAccount
      or not career_modules_bank.rewardToAccount then
      return false
    end

    local businessAccount = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
    local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
    if not accountId then
      return false
    end

    local credited = career_modules_bank.rewardToAccount({
      money = {
        amount = salePrice
      }
    }, accountId, "Vehicle Sale", "Sold vehicle from racing team inventory")

    if not credited then
      return false
    end
  end

  local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
  local inv = career_modules_business_businessInventory

  local function finishAbandonJobAfterPutAway()
    if inv.removeVehicle then
      inv.removeVehicle(businessId, vehicleToRemove.vehicleId)
    else
      return false
    end

    clearRacingTeamDriverAssignmentForJob(businessId, job.jobId)
    table.remove(state.active, foundIndex)
    if getRacingTeamDriverCapacity(businessId) >= 1 then
      racingTeamPersistDrivers(businessId)
    end
    if career_saveSystem.saveCurrent then
      career_saveSystem.saveCurrent()
    end
    if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
      rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
    end
    return true
  end

  local scheduledPutAway = false
  if inv.getPulledOutVehicles then
    local pulledVehicles = inv.getPulledOutVehicles(businessId) or {}
    for _, pulled in ipairs(pulledVehicles) do
      local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
      if pulledId == removeId and inv.putAwayVehicle then
        inv.putAwayVehicle(businessId, removeId, function()
          finishAbandonJobAfterPutAway()
        end)
        scheduledPutAway = true
        break
      end
    end
  else
    local getPulled = inv.getPulledOutVehicle
    local pulledOutVehicle = getPulled and getPulled(businessId)
    if pulledOutVehicle and inv.putAwayVehicle then
      local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
      if pulledId == removeId then
        inv.putAwayVehicle(businessId, nil, function()
          finishAbandonJobAfterPutAway()
        end)
        scheduledPutAway = true
      end
    end
  end
  
  if not scheduledPutAway then
    return finishAbandonJobAfterPutAway()
  end
  return true
end

local function sellVehicle(businessId, vehicleId)
  if not businessId or vehicleId == nil or vehicleId == false or vehicleId == "" then
    return false
  end
  if not career_modules_business_businessInventory then
    return false
  end

  local state = getOfferState(businessId)
  local removeId = tonumber(vehicleId) or vehicleId
  local vehicleToRemove = career_modules_business_businessInventory.getVehicleById
    and career_modules_business_businessInventory.getVehicleById(businessId, removeId)
    or nil
  if not vehicleToRemove then
    return false
  end

  local linkedJobIdx, linkedJob = findActiveVehicleJobByVehicleId(state, removeId)
  local saleFallback = tonumber(linkedJob and linkedJob.reward) or 0
  local salePrice = getTeamVehicleSellValue(vehicleToRemove, saleFallback)
  if salePrice > 0 then
    if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.rewardToAccount then
      return false
    end
    local businessAccount = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
    local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
    if not accountId then
      return false
    end
    local credited = career_modules_bank.rewardToAccount({
      money = { amount = salePrice }
    }, accountId, "Vehicle Sale", "Sold vehicle from racing team inventory")
    if not credited then
      return false
    end
  end

  local inv = career_modules_business_businessInventory

  local function finishSellVehicleAfterPutAway()
    if not inv.removeVehicle or not inv.removeVehicle(businessId, removeId) then
      return false
    end

    if linkedJobIdx and linkedJob then
      clearRacingTeamDriverAssignmentForJob(businessId, linkedJob.jobId)
      table.remove(state.active, linkedJobIdx)
      if getRacingTeamDriverCapacity(businessId) >= 1 then
        racingTeamPersistDrivers(businessId)
      end
    end

  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
    if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
      rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
    end
  return true
end

  local scheduledPutAway = false
  if inv.getPulledOutVehicles then
    local pulledVehicles = inv.getPulledOutVehicles(businessId) or {}
    for _, pulled in ipairs(pulledVehicles) do
      local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
      if pulledId == removeId and inv.putAwayVehicle then
        inv.putAwayVehicle(businessId, removeId, function()
          finishSellVehicleAfterPutAway()
        end)
        scheduledPutAway = true
        break
      end
    end
  else
    local getPulled = inv.getPulledOutVehicle
    local pulledOutVehicle = getPulled and getPulled(businessId)
    if pulledOutVehicle and inv.putAwayVehicle then
      local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
      if pulledId == removeId then
        inv.putAwayVehicle(businessId, nil, function()
          finishSellVehicleAfterPutAway()
        end)
        scheduledPutAway = true
      end
    end
  end

  if not scheduledPutAway then
    return finishSellVehicleAfterPutAway()
  end
  return true
end

local function buildRacingTeamLeague2InvitePayload(businessId, currentLeagueResolved)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local lvUiInf = getRacingTeamLevelInfo(getRacingTeamLevelId())
  local wInv = getLeague2InviteTable(businessId)
  local idPromo = league2InvitePromoKey(businessId)
  local promoUiState = rtState.league2InvitePromoUiByBusiness[idPromo]
  local leagueForUi = currentLeagueResolved or rtState.rtInternal.getCurrentLeague(businessId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(leagueForUi)
  local target = wInv.targetLeague or nextLeague or "league2"
  local cfg = rtState.rtInternal.getLeagueInviteConfigForTarget(lvUiInf, target)
  local inviteEligible = nextLeague ~= nil
    and wInv.declined ~= true
    and wInv.offeredAt ~= nil
    and (wInv.targetLeague == nil or wInv.targetLeague == nextLeague)
    and rtState.rtInternal.allGoalsCompleteForLeague(businessId, leagueForUi)
  local league2InviteComputerPopup = inviteEligible and promoUiState == "splash"
  local league2InviteVisible = inviteEligible and promoUiState == "jobs"
  local nowSim = getCareerSimTime()
  local league2InviteFeeMinutesUntilEscalate = nil
  local escMinUi = cfg.feeEscalateMinutes
  if wInv.offeredAt then
    local deadline = wInv.offeredAt + escMinUi
    if nowSim < deadline then
      league2InviteFeeMinutesUntilEscalate = math.max(0, math.ceil(deadline - nowSim))
    end
  end
  return {
    visible = league2InviteVisible,
    computerPopup = league2InviteComputerPopup,
    targetLeague = cfg.targetLeague,
    popupTitle = cfg.splashTitle,
    popupBody = cfg.splashBody,
    popupImageUrl = cfg.splashImageUrl,
    acceptLabel = cfg.splashAcceptLabel,
    laterLabel = cfg.splashLaterLabel,
    acronym = cfg.acronym,
    orgName = cfg.orgName,
    fee = getLeague2InviteFeeAmount(businessId),
    feeEarly = cfg.feeEarly,
    feeLate = cfg.feeLate,
    offeredAtSimTime = wInv.offeredAt,
    escalateAtSimTime = (wInv.offeredAt and (wInv.offeredAt + escMinUi)) or nil,
    minutesUntilEscalate = league2InviteFeeMinutesUntilEscalate,
  }
end

local function buildRacingTeamUIDataFallback(businessId, errMsg)
  ensureTabsRegistered()
  local tabs = {}
  if career_modules_business_businessTabRegistry then
    tabs = career_modules_business_businessTabRegistry.getTabs(rtState.businessType) or {}
  end
  local league = "league1"
  local okLeague, v = pcall(rtState.rtInternal.getCurrentLeague, businessId)
  if okLeague and type(v) == "string" and v ~= "" then
    league = v
  end
  log('E', 'racingTeam', 'getUIData failed; using fallback. ' .. tostring(errMsg))
  local fbLev = getRacingTeamLevelInfo(getRacingTeamLevelId())
  local fbTarget = rtState.rtInternal.getNextLeagueForPromotion(league) or "league2"
  local fbCfg = rtState.rtInternal.getLeagueInviteConfigForTarget(fbLev, fbTarget)
  local league2InviteSafe = {
    visible = false,
    computerPopup = false,
    targetLeague = fbCfg.targetLeague,
    popupTitle = fbCfg.splashTitle,
    popupBody = fbCfg.splashBody,
    acceptLabel = fbCfg.splashAcceptLabel,
    laterLabel = fbCfg.splashLaterLabel,
    acronym = fbCfg.acronym,
    orgName = fbCfg.orgName,
    fee = fbCfg.feeEarly,
    feeEarly = fbCfg.feeEarly,
    feeLate = fbCfg.feeLate,
  }
  local okL2, l2Payload = pcall(function()
    local bid = normalizeBusinessId(businessId)
    if not bid then
      return nil
    end
    rtState.rtInternal.refreshLeague2InviteOffer(bid)
    local _, _, clr = buildRacingTeamGoalDisplays(bid)
    return buildRacingTeamLeague2InvitePayload(bid, clr)
  end)
  if okL2 and type(l2Payload) == "table" then
    league2InviteSafe = l2Payload
  end
  return {
    businessId = businessId,
    businessType = rtState.businessType,
    businessName = "Racing Team",
    currentGoal = nil,
    currentLeague = league,
    activeGoals = {},
    completedGoals = {},
    activeJobs = {},
    newJobs = {},
    vehicles = {},
    parts = {},
    pulledOutVehicle = nil,
    pulledOutVehicles = {},
    activeVehicleId = nil,
    maxPulledOutVehicles = 1,
    tabs = tabs,
    techs = {},
    vehicleDamage = 0,
    vehicleDamageLocked = false,
    vehicleDamageThreshold = 1000,
    maxActiveJobs = 3,
    playerInZone = false,
    raceOffers = {},
    raceOffersLevelId = "",
    raceOffersNextRefreshAt = 0,
    raceOffersMessage = "Some racing team data could not be loaded. Check beamng.log for details.",
    racingTeamProxyArmed = false,
    racingTeamManagerSkillLevel = 0,
    racingTeamManagerAutoAssign = false,
    league2Invite = league2InviteSafe,
    racingTeamLeagueDisplayNames = shallowCopyTable(fbLev.leagueDisplayNames),
    racingTeamLevelExtra = shallowCopyTable(fbLev.extra),
    racingTeamSponsors = {
      available = {},
      active = {},
      sponsorSlots = rtState.K.RACING_TEAM_SPONSOR_MAX_ACTIVE,
      sponsorSlotsUsed = 0,
      bonusMoneyTotal = 0,
      bonusXpTotal = 0,
    },
  }
end

local function buildRacingTeamUIDataCore(businessId)
  if racingTeamBuildClass and racingTeamBuildClass.warmupCatalogBaselines then racingTeamBuildClass.warmupCatalogBaselines() end
  local business = freeroam_facilities.getFacility(rtState.businessType, businessId)

  local businessName = (business and business.name) or "Racing Team"

  local offerState = getOfferState(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  tickRacingTeamSponsorOffers(businessId)
  if not business and career_modules_business_businessManager and career_modules_business_businessManager.getBusinessInfo then
    local savedInfo = career_modules_business_businessManager.getBusinessInfo(rtState.businessType, businessId)
    if savedInfo and savedInfo.name then
      businessName = savedInfo.name
    end
  end

  local vehicles = {}
  local pulledOutVehiclesRaw = {}
  if career_modules_business_businessInventory then
    vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
    if career_modules_business_businessInventory.getPulledOutVehicles then
      pulledOutVehiclesRaw = career_modules_business_businessInventory.getPulledOutVehicles(businessId) or {}
    end
  end

  local vehicleList = {}
  for _, vehicle in ipairs(vehicles) do
    local formatted = rtState.formatVehicleForUI(vehicle, businessId)
    if formatted then
      table.insert(vehicleList, formatted)
    end
  end
  do
    local shopping = rawget(_G, "career_modules_vehicleShopping")
    local pending = {}
    if shopping and shopping.getPendingRacingTeamFleetPurchases then
      pending = shopping.getPendingRacingTeamFleetPurchases(businessId) or {}
    end
    local nowEpoch = os.time()
    for _, p in ipairs(pending) do
      local modelKey = p.model_key
      local configKey = p.key
      local name, vehicleYear, vehicleType, vehicleImage =
        career_modules_business_businessHelpers.extractDisplayInfo(getCatalogVehicleInfo(modelKey, configKey))
      local vehicleName = name or modelKey or "Vehicle Delivery"
      table.insert(vehicleList, {
        id = "pending_" .. tostring(p.pendingId or #vehicleList + 1),
        vehicleId = nil,
        vehicleName = vehicleName,
        vehicleYear = vehicleYear,
        vehicleType = vehicleType,
        vehicleImage = vehicleImage,
        storedTime = tonumber(p.purchasedEpoch) or nowEpoch,
        model_key = modelKey,
        config_key = configKey,
        vehicleValue = math.max(0, math.floor(tonumber(p.purchasePrice) or 0)),
        sellValue = 0,
        fleetRepairNeeded = false,
        fleetRepairDeductible = 0,
        deliveryPending = true,
        deliveryMode = tostring(p.kind or "timer"),
        deliveryDueEpoch = tonumber(p.dueEpoch) or 0,
        deliverySecondsRemaining = math.max(0, math.floor(tonumber(p.secondsRemaining) or ((tonumber(p.dueEpoch) or nowEpoch) - nowEpoch))),
      })
    end
  end

  local formattedPulledOutVehicles = {}
  local pulledOutVehicleData = nil
  local activeVehicleId = nil
  local topVehicleDamage = 0
  local topVehicleDamageLocked = false
  for i, vehicle in ipairs(pulledOutVehiclesRaw) do
    local formatted = rtState.formatVehicleForUI(vehicle, businessId)
    if formatted then
      formatted.inGarageZone = true
      formatted.isActive = (i == 1)
      local dmgInfo = getSpawnedBusinessVehicleDamageInfo(businessId, vehicle.vehicleId)
      formatted.damage = dmgInfo.damage
      formatted.damageLocked = false
      formatted.damageThreshold = dmgInfo.threshold
      table.insert(formattedPulledOutVehicles, formatted)
      if i == 1 then
        pulledOutVehicleData = formatted
        activeVehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
        topVehicleDamage = dmgInfo.damage
        topVehicleDamageLocked = false
      end
    end
  end
  
  local currentGoal, activeGoals, currentLeagueResolved = buildRacingTeamGoalDisplays(businessId)
  rtState.rtInternal.refreshLeague2InviteOffer(businessId)
  local completedGoals = getCompletedGoalsList(businessId)
  if rtState.raceUnlockSplashPendingByBusiness[id] then
    rtState.raceUnlockSplashPendingByBusiness[id] = false
    local shouldShowRaceUnlockSplash = rtState.raceUnlockSplashShownByBusiness[id] ~= true
    if shouldShowRaceUnlockSplash then
      rtState.raceUnlockSplashShownByBusiness[id] = true
    end
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      saveRacingTeamPersistedState(businessId, savePath)
    end
    if shouldShowRaceUnlockSplash then
      if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
          job.sleep(0.35)
          rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "race_unlock")
        end)
      else
        rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "race_unlock")
      end
    end
  end
  if rtState.careerFinaleSplashPendingByBusiness[id] then
    rtState.careerFinaleSplashPendingByBusiness[id] = false
    if rtState.careerFinaleSplashShownByBusiness[id] ~= true and rtState.rtInternal.scheduleCareerFinaleSplash then
      local _, savePathFinale = career_saveSystem.getCurrentProfile()
      if savePathFinale then
        saveRacingTeamPersistedState(businessId, savePathFinale)
      end
      rtState.rtInternal.scheduleCareerFinaleSplash(businessId)
    end
  end
  rtState.loadRacingTeamDrivers(businessId)
  local techEntries = {}
  for _, tech in ipairs(getRacingTeamDriversRawForUI(businessId)) do
    local formattedTech = formatRacingTeamDriverForUI(businessId, tech)
    if formattedTech then
      table.insert(techEntries, formattedTech)
    end
  end
  local raceBoard = ensureRaceOfferBoard(businessId)
  local raceOffersRaw = raceBoard.offers or {}
  local raceOffers = {}
  if type(raceOffersRaw) == "table" then
    local srDisp = gameplay_events_freContracts_sanctionedRacing
    for _, o in ipairs(raceOffersRaw) do
      if srDisp and type(srDisp.attachSanctionedOfferDisplayHp) == "function" then
        srDisp.attachSanctionedOfferDisplayHp(o)
      end
      table.insert(raceOffers, o)
    end
  end
  local lvUiInf = getRacingTeamLevelInfo(getRacingTeamLevelId())
  local raceOffersMessage = nil
  if raceBoard.levelId == "" then
    raceOffersMessage = "Open the business computer while on a career map to load sanctioned race offers."
  elseif #raceOffers == 0 then
    raceOffersMessage = lvUiInf.msgNoSanctionedRaces
  end
  local stSp = getRacingTeamSponsorState(businessId)
  local spMoney, spXp = racingTeamSponsorBonusTotals(businessId)
  local racingTeamManagerSkillLevel = 0
  local racingTeamManagerAutoAssign = false
  if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.getNodeProgress then
    racingTeamManagerSkillLevel = math.max(
      0,
      math.floor(tonumber(career_modules_business_businessSkillTree.getNodeProgress(businessId, "team-operations", "manager")) or 0)
    )
  end
  if racingTeamManager and racingTeamManager.getManagerAutoAssignEnabled then
    racingTeamManagerAutoAssign = racingTeamManager.getManagerAutoAssignEnabled(businessId)
  end
  local racingTeamManagerAssignIntervalSec = nil
  local racingTeamManagerAssignIntervalRemainingSec = nil
  local racingTeamManagerNextAssignWallEpoch = nil
  local racingTeamManagerAssignIntervalOptions = nil
  if racingTeamManager and racingTeamManagerSkillLevel > 0 then
    if racingTeamManager.processAssignDueNow then
      pcall(racingTeamManager.processAssignDueNow, businessId)
    end
    if racingTeamManager.getManagerAssignIntervalSec then
      racingTeamManagerAssignIntervalSec = racingTeamManager.getManagerAssignIntervalSec(businessId)
    end
    if racingTeamManager.getManagerAssignIntervalRemainingSec then
      racingTeamManagerAssignIntervalRemainingSec = racingTeamManager.getManagerAssignIntervalRemainingSec(businessId)
    end
    if racingTeamManager.getManagerNextAssignWallEpoch then
      racingTeamManagerNextAssignWallEpoch = racingTeamManager.getManagerNextAssignWallEpoch(businessId)
    end
    if racingTeamManager.getAssignIntervalOptionsForUI then
      racingTeamManagerAssignIntervalOptions = racingTeamManager.getAssignIntervalOptionsForUI()
    end
  end
  return {
    businessId = businessId,
    businessType = rtState.businessType,
    businessName = businessName,
    currentGoal = currentGoal,
    currentLeague = currentLeagueResolved or rtState.rtInternal.getCurrentLeague(businessId),
    league2Invite = buildRacingTeamLeague2InvitePayload(businessId, currentLeagueResolved),
    racingTeamLeagueDisplayNames = shallowCopyTable(lvUiInf.leagueDisplayNames),
    racingTeamLevelExtra = shallowCopyTable(lvUiInf.extra),
    racingTeamSponsors = {
      available = stSp.available or {},
      active = stSp.active or {},
      sponsorSlots = rtState.K.RACING_TEAM_SPONSOR_MAX_ACTIVE,
      sponsorSlotsUsed = #(stSp.active or {}),
      bonusMoneyTotal = spMoney,
      bonusXpTotal = spXp,
    },
    activeGoals = activeGoals,
    completedGoals = completedGoals,
    activeJobs = offerState.active or {},
    newJobs = offerState.new or {},
    vehicles = vehicleList,
    parts = {},
    pulledOutVehicle = pulledOutVehicleData,
    pulledOutVehicles = formattedPulledOutVehicles,
    activeVehicleId = activeVehicleId,
    maxPulledOutVehicles = getMaxPulledOutVehicles(businessId),
    tabs = (function()
      ensureTabsRegistered()
      if career_modules_business_businessSkillTree and career_modules_business_businessSkillTree.ensureTabsRegistered then
        pcall(career_modules_business_businessSkillTree.ensureTabsRegistered, rtState.businessType)
      end
      if career_modules_business_businessTabRegistry then
        return career_modules_business_businessTabRegistry.getTabs(rtState.businessType) or {}
      end
      return {}
    end)(),
    techs = techEntries,
    vehicleDamage = topVehicleDamage,
    vehicleDamageLocked = topVehicleDamageLocked,
    vehicleDamageThreshold = getDamageThreshold(businessId),
    maxActiveJobs = getMaxActiveJobs(businessId),
    playerInZone = false,
    raceOffers = raceOffers,
    raceOffersLevelId = raceBoard.levelId or "",
    raceOffersNextRefreshAt = tonumber(raceBoard.nextRefreshAt) or 0,
    raceOffersMessage = raceOffersMessage,
    racingTeamProxyArmed = (function()
      local pr = getProxyDriverRaceRequest(businessId)
      return pr ~= nil and pr.racingTeamProxyRace == true
    end)(),
    racingTeamManagerSkillLevel = racingTeamManagerSkillLevel,
    racingTeamManagerAutoAssign = racingTeamManagerAutoAssign,
    racingTeamManagerAssignIntervalSec = racingTeamManagerAssignIntervalSec,
    racingTeamManagerAssignIntervalRemainingSec = racingTeamManagerAssignIntervalRemainingSec,
    racingTeamManagerNextAssignWallEpoch = racingTeamManagerNextAssignWallEpoch,
    racingTeamManagerAssignIntervalOptions = racingTeamManagerAssignIntervalOptions,
    racingTeamManagerAutoStartRaces = rtState.autoStartBackgroundRacesByBusiness[tostring(normalizeBusinessId(businessId))] ~= false,
    activeBackgroundRace = racingTeamRaceSim.getActiveSim(businessId) ~= nil,
    racingTeamFleetCooldowns = (function()
      local out = {}
      local inv = career_modules_business_businessInventory
      if inv and inv.getBusinessVehicles then
        local vehs = inv.getBusinessVehicles(businessId) or {}
        for _, v in ipairs(vehs) do
          local vid = v and (tonumber(v.vehicleId) or v.vehicleId)
          if vid ~= nil then
            local sec = getFleetVehiclePostRaceCooldownRemainingSec(businessId, vid) or 0
            if sec > 0 then
              out[tostring(vid)] = sec
            end
          end
        end
      end
      return out
    end)(),
  }
end

rtState.rtInternal.getUIData = function(businessId)
  if not businessId then
    return nil
  end
  local ok, result = pcall(buildRacingTeamUIDataCore, businessId)
  if ok then
    return result
  end
  return buildRacingTeamUIDataFallback(businessId, result)
end

rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer = function(businessId)
  if not guihooks or not guihooks.trigger then
    return
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local uid = rtState.rtInternal.getUIData(businessId)
  if not uid then
    return
  end
  local inv = uid.league2Invite
  local cp = inv and inv.computerPopup
  local vis = inv and inv.visible
  local msg = string.format(
    "[racingTeam] pushRacingTeamGoalsToBusinessComputer: bid=%s computerPopup=%s visible=%s -> onRacingTeamGoals",
    tostring(businessId),
    tostring(cp),
    tostring(vis)
  )
  log("I", "racingTeam", msg)
  guihooks.trigger("businessComputer:onRacingTeamGoals", {
    businessId = businessId,
    currentGoal = uid.currentGoal,
    currentLeague = uid.currentLeague,
    completedGoals = uid.completedGoals,
    league2Invite = uid.league2Invite,
    vehicles = uid.vehicles,
  })
end

local function scheduleDeferredRacingTeamGoalsPushWithRetry(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local id = tostring(businessId)
  rtState.rtInternal.goalsPushToken[id] = (rtState.rtInternal.goalsPushToken[id] or 0) + 1
  local token = rtState.rtInternal.goalsPushToken[id]
  local initialDelay = 2.5
  local retryGap = 2.0
  local function doPushIfCurrent()
    if rtState.rtInternal.goalsPushToken[id] ~= token then
      return
    end
    rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  end
  if not core_jobsystem or not core_jobsystem.create then
    doPushIfCurrent()
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(initialDelay)
    doPushIfCurrent()
    job.sleep(retryGap)
    doPushIfCurrent()
  end)
end

rtState.rtInternal.notifyBusinessComputerRacingTeamGoalProgress = function(businessId, goalId)
  if goalId ~= rtState.K.GOAL_TIER1_LAST then
    return
  end
  scheduleDeferredRacingTeamGoalsPushWithRetry(businessId)
end

local function openMenu(businessId)
  extensions.ui_router.navigate('business-computer', {
    businessType = rtState.businessType,
    businessId = businessId
  })
end

local function getLiquidationValue(businessId)
  if not career_modules_business_businessInventory then
    return 0
  end
  local total = 0
  for _, vehicle in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
    total = total + (getTeamVehicleSellValue(vehicle, 0) or 0)
  end
  if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.getLiquidationValue then
    total = total + (career_modules_business_businessPartInventory.getLiquidationValue(businessId) or 0)
  end
  return math.floor(total + 0.5)
end

local function resetBusinessForSale(businessId)
  local bid = normalizeBusinessId(businessId)
  if not bid then return false end
  local id = tostring(bid)

  local leaderboardInventoryIdsToClear = {}
  do
    local inv = career_modules_business_businessInventory
    if inv then
      local seen = {}
      if inv.getBusinessVehicles and inv.getBusinessVehicleIdentifier then
        for _, v in ipairs(inv.getBusinessVehicles(bid) or {}) do
          local vid = v and (tonumber(v.vehicleId) or v.vehicleId)
          if vid ~= nil then
            local s = inv.getBusinessVehicleIdentifier(bid, vid)
            if s and not seen[s] then
              seen[s] = true
              table.insert(leaderboardInventoryIdsToClear, s)
            end
          end
          if v and v.jobId ~= nil and inv.getBusinessJobIdentifier then
            local s = inv.getBusinessJobIdentifier(bid, v.jobId)
            if s and not seen[s] then
              seen[s] = true
              table.insert(leaderboardInventoryIdsToClear, s)
            end
          end
        end
      end
      if inv.getBusinessJobIdentifier and rtState and rtState.offerStateByBusiness then
        local offerSt = rtState.offerStateByBusiness[id]
        if offerSt and type(offerSt.active) == "table" then
          for _, activeJob in ipairs(offerSt.active) do
            if activeJob and activeJob.jobId ~= nil then
              local s = inv.getBusinessJobIdentifier(bid, activeJob.jobId)
              if s and not seen[s] then
                seen[s] = true
                table.insert(leaderboardInventoryIdsToClear, s)
              end
            end
            if activeJob and activeJob.storedVehicleId ~= nil then
              local s = inv.getBusinessJobIdentifier(bid, activeJob.storedVehicleId)
              if s and not seen[s] then
                seen[s] = true
                table.insert(leaderboardInventoryIdsToClear, s)
              end
            end
          end
        end
      end
    end
  end

  if career_modules_business_businessInventory and career_modules_business_businessInventory.clearBusinessInventory then
    career_modules_business_businessInventory.clearBusinessInventory(bid)
  end
  if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.clearBusinessParts then
    career_modules_business_businessPartInventory.clearBusinessParts(bid)
  end
  if career_modules_vehicleShopping and career_modules_vehicleShopping.clearPendingRacingTeamFleetPurchases then
    career_modules_vehicleShopping.clearPendingRacingTeamFleetPurchases(bid)
  end

  do
    local lb = gameplay_events_freeroam_leaderboardManager
    if lb and lb.clearLeaderboardInventoriesBatchAtAllLevels and #leaderboardInventoryIdsToClear > 0 then
      pcall(lb.clearLeaderboardInventoriesBatchAtAllLevels, leaderboardInventoryIdsToClear)
    end
  end

  rtState.offerStateByBusiness[id] = { new = {}, active = {} }
  rtState.goalCompletionByBusiness[id] = {}
  rtState.tuningMilestoneByBusiness[id] = nil
  rtState.tuningMilestoneByGoalByBusiness[id] = {}
  rtState.homeMechanicBaselinePwByBusiness[id] = nil
  rtState.pendingHomeMechanicPwRecheckByBusiness[id] = nil
  rtState.currentLeagueByBusiness[id] = "league1"
  rtState.offerJobIdCounters[id] = 0
  rtState.staminaShortTrackStreakByBusiness[id] = nil
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] = nil
  rtState.classOptimizationPeakHpByBusiness[id] = nil
  rtState.dynoRequiredByBusiness[id] = nil
  rtState.persistLoaded[id] = true
  rtState.vehicleCooldownByBusiness[id] = nil
  rtState.playerCooldownByBusiness[id] = nil
  rtState.allLeaderboardsBaselineByBusiness[id] = nil
  rtState.completedGoalLeaderboardTimesByBusiness[id] = nil
  rtState.raceOfferBoardByBusiness[id] = nil
  rtState.pendingRematchOfferByBusiness[id] = nil
  rtState.businessSkillXpByBusiness[id] = 0
  rtState.league2InviteByBusiness[id] = nil
  rtState.league2InvitePromoUiByBusiness[id] = nil
  rtState.purchaseMilestoneSplashShownByBusiness[id] = nil
  rtState.raceUnlockSplashPendingByBusiness[id] = nil
  rtState.raceUnlockSplashShownByBusiness[id] = nil
  rtState.careerFinaleSplashPendingByBusiness[id] = nil
  rtState.careerFinaleSplashShownByBusiness[id] = nil
  rtState.rtInternal.league2SplashQueued[id] = nil
  rtState.rtInternal.purchaseSplashQueued[id] = nil
  rtState.rtInternal.goalsPushToken[id] = nil
  rtState.rtInternal.sponsors[id] = nil
  rtState.businessDrivers[bid] = {}

  local proxyFlow = raceFlowMod()
  if proxyFlow and proxyFlow.clearProxyDriverRaceRequest then
    pcall(proxyFlow.clearProxyDriverRaceRequest, bid)
  end
  if racingTeamFinances and racingTeamFinances.clearOperatingCostTimer then
    racingTeamFinances.clearOperatingCostTimer(bid)
  end

  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(bid, savePath)
    saveRacingTeamDrivers(bid, savePath)
  end

  if guihooks then
    guihooks.trigger("businessComputer:onRacingTeamGoals", {
      businessId = bid,
      currentGoal = nil,
      currentLeague = "league1",
      completedGoals = {},
      vehicles = {},
    })
  end
  return true
end

local businessObject = {
  businessType = rtState.businessType,
  features = {
    skillTrees = true,
    bankAccount = true,
    inventory = true,
    xpSystem = true,
  },
  getUIData = function(businessId) return rtState.rtInternal.getUIData(businessId) end,
  getDamageThreshold = function(businessId) return getDamageThreshold(businessId) end,
  getMaxPulledOutVehicles = function(businessId) return getMaxPulledOutVehicles(businessId) end,
  getMaxActiveJobs = function(businessId) return getMaxActiveJobs(businessId) end,
  getBusinessXP = function(businessId) return getRacingTeamBusinessSkillXpValue(businessId) end,
  addBusinessXP = function(businessId, amount) return addRacingTeamBusinessSkillXpValue(businessId, amount) end,
  spendBusinessXP = function(businessId, amount) return spendRacingTeamBusinessSkillXpValue(businessId, amount) end,
  getLiquidationValue = function(businessId) return getLiquidationValue(businessId) end,
  resetBusinessForSale = function(businessId) return resetBusinessForSale(businessId) end,
  getTechsForBusiness = function(businessId) return getRacingTeamDriversRawForUI(businessId) end,
  formatTechForUIEntry = function(businessId, tech) return formatRacingTeamDriverForUI(businessId, tech) end,
}

local function onSaveCurrentProfile(currentSavePath)
  if not currentSavePath then
    return
  end
  racingTeamFinances.saveOperatingCostTimers(currentSavePath)
  if racingTeamManager and racingTeamManager.onSaveCurrentProfile then
    racingTeamManager.onSaveCurrentProfile(currentSavePath)
  end
  local seen = {}
  local purchased = career_modules_business_businessManager
    and career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType)
  if purchased then
    for bid, _ in pairs(purchased) do
      getOfferState(bid)
      saveRacingTeamPersistedState(bid, currentSavePath)
      rtState.loadRacingTeamDrivers(bid)
      saveRacingTeamDrivers(bid, currentSavePath)
      seen[tostring(normalizeBusinessId(bid))] = true
    end
  end
  for idStr, _ in pairs(rtState.offerStateByBusiness) do
    if not seen[idStr] then
      local bid = tonumber(idStr) or idStr
      saveRacingTeamPersistedState(bid, currentSavePath)
      rtState.loadRacingTeamDrivers(bid)
      saveRacingTeamDrivers(bid, currentSavePath)
    end
  end
end

local function onCareerActivated()
  rtState.scheduledRaceReadyToastAccumulator = 0
  rtState.offerStateByBusiness = {}
  rtState.goalCompletionByBusiness = {}
  rtState.tuningMilestoneByBusiness = {}
  rtState.tuningMilestoneByGoalByBusiness = {}
  rtState.homeMechanicBaselinePwByBusiness = {}
  rtState.pendingHomeMechanicPwRecheckByBusiness = {}
  rtState.currentLeagueByBusiness = {}
  rtState.offerJobIdCounters = {}
  rtState.persistLoaded = {}
  rtState.raceOfferBoardByBusiness = {}
  rtState.pendingRematchOfferByBusiness = {}
  local proxyFlow = raceFlowMod()
  if proxyFlow and proxyFlow.onCareerActivated then
    proxyFlow.onCareerActivated()
  end
  rtState.businessSkillXpByBusiness = {}
  rtState.staminaShortTrackStreakByBusiness = {}
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness = {}
  rtState.classOptimizationPeakHpByBusiness = {}
  rtState.dynoRequiredByBusiness = {}
  rtState.autoStartBackgroundRacesByBusiness = {}
  rtState.businessDrivers = {}
  rtState.league2InviteByBusiness = {}
  rtState.league2InvitePromoUiByBusiness = {}
  rtState.purchaseMilestoneSplashShownByBusiness = {}
  rtState.raceUnlockSplashPendingByBusiness = {}
  rtState.raceUnlockSplashShownByBusiness = {}
  rtState.careerFinaleSplashPendingByBusiness = {}
  rtState.careerFinaleSplashShownByBusiness = {}
  rtState.rtInternal.league2SplashQueued = {}
  rtState.rtInternal.purchaseSplashQueued = {}
  rtState.rtInternal.goalsPushToken = {}
  rtState.rtInternal.sponsors = {}
  rtState.rtInternal.racingTeamLevelInfoNormalizedCache = {}
  rtState.rtInternal.goalsDefinitionLoaded = false
  rtState.rtInternal.goalsDefinition = nil
  rtState.rtInternal.eligibleVehicleInfoByPair = nil
  rtState.rtInternal.lastPostRaceRemByTech = {}
  rtState.postRaceCooldownUiPollAccumulator = 0
  rtState.allLeaderboardsBaselineByBusiness = {}
  rtState.completedGoalLeaderboardTimesByBusiness = {}
  racingTeamRaceSim.onCareerActivated()
  racingTeamFinances.onCareerActivated()
  racingTeamManager.onCareerActivated()
  career_modules_business_businessManager.registerBusiness(rtState.businessType, businessObject)
  ensureTabsRegistered()

  career_modules_business_businessManager.registerBusinessCallback(rtState.businessType, {
    onPurchase = function(businessId)
      if career_modules_bank then
        local accountId = "business_" .. rtState.businessType .. "_" .. tostring(businessId)
        local capitalInjectionAmount = career_modules_business_businessManager.getPurchaseCapitalInjectionAmount(0)
        if capitalInjectionAmount > 0 then
          career_modules_bank.rewardToAccount({
            money = { amount = capitalInjectionAmount }
          }, accountId, "Capital Injection", "Initial operating capital")
        end
      end
      getOfferState(businessId)
      rtState.rtInternal.schedulePurchaseMilestoneSplash(businessId)
      career_saveSystem.saveCurrent()
    end,
    onMenuOpen = function(businessId)
      if racingTeamBuildClass and racingTeamBuildClass.warmupCatalogBaselines then racingTeamBuildClass.warmupCatalogBaselines() end
      openMenu(businessId)
    end
  })
  if racingTeamBuildClass and racingTeamBuildClass.warmupCatalogBaselines then racingTeamBuildClass.warmupCatalogBaselines() end
end

M.onCareerActivated = onCareerActivated
M.onSaveCurrentProfile = onSaveCurrentProfile
M.refreshDevConsoleTab = ensureTabsRegistered

local function tickPostRaceCooldownDriverUiPushAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return
  end
  local bm = career_modules_business_businessManager
  if not bm or not bm.getPurchasedBusinesses then
    return
  end
  rtState.postRaceCooldownUiPollAccumulator = rtState.postRaceCooldownUiPollAccumulator + dtSim
  if rtState.postRaceCooldownUiPollAccumulator < rtState.K.POST_RACE_COOLDOWN_UI_POLL_INTERVAL_SIM then
    return
  end
  rtState.postRaceCooldownUiPollAccumulator = 0

  local purchased = bm.getPurchasedBusinesses(rtState.businessType) or {}
  local lastMap = rtState.rtInternal.lastPostRaceRemByTech or {}
  rtState.rtInternal.lastPostRaceRemByTech = lastMap

  for bid, _ in pairs(purchased) do
    local nb = normalizeBusinessId(bid)
    if nb then
      getOfferState(nb)
      rtState.loadRacingTeamDrivers(nb)
      local techs = rtState.businessDrivers[nb] or {}
      local anyTransition = false
      for _, tech in ipairs(techs) do
        if tech and tech.id and not tech.fired then
          local key = tostring(nb) .. "_" .. tostring(tech.id)
          local rem = getRacingTeamDriverPostRaceCooldownRemainingSec(nb, tech)
          local prev = lastMap[key]
          if prev ~= nil and prev > 0 and rem <= 0 then
            anyTransition = true
          end
          lastMap[key] = rem > 0 and rem or 0
        end
      end
      if anyTransition then
        racingTeamPersistDrivers(nb)
        notifyRacingTeamDriversUpdated(nb)
      end
    end
  end
end

local function tickScheduledRaceReadyToastsAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return
  end
  rtState.scheduledRaceReadyToastAccumulator = rtState.scheduledRaceReadyToastAccumulator + dtSim
  if rtState.scheduledRaceReadyToastAccumulator < rtState.K.SCHEDULED_RACE_READY_TOAST_INTERVAL then
    return
  end
  rtState.scheduledRaceReadyToastAccumulator = 0
  processScheduledRaceReadyToastQueue()
end

local function tickRacingTeamManagerAccumulated(dtSim)
  if racingTeamManager and racingTeamManager.tickAccumulated then
    racingTeamManager.tickAccumulated(dtSim)
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not career_career or not career_career.isActive or not career_career.isActive() then return end
  local deltaSim = math.max(dtSim or 0, 0)
  if deltaSim <= 0 then return end
  
  tickScheduledRaceReadyToastsAccumulated(deltaSim)
  tickPostRaceCooldownDriverUiPushAccumulated(deltaSim)
  if racingTeamManager and racingTeamManager.tickAccumulated then
    racingTeamManager.tickAccumulated(deltaSim)
  end
  if racingTeamRaceSim and racingTeamRaceSim.tickAccumulated then
    racingTeamRaceSim.tickAccumulated(deltaSim)
  end
end

function M.getAutoStartBackgroundRaces(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  local val = rtState.autoStartBackgroundRacesByBusiness[id]
  if val == nil then return true end
  return val == true
end

function M.setAutoStartBackgroundRaces(businessId, enabled)
  local id = tostring(normalizeBusinessId(businessId))
  if not rtState.autoStartBackgroundRacesByBusiness then
    rtState.autoStartBackgroundRacesByBusiness = {}
  end
  rtState.autoStartBackgroundRacesByBusiness[id] = (enabled == true)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveRacingTeamPersistedState(businessId, savePath)
  end
  if guihooks and guihooks.trigger then
    guihooks.trigger("racingTeamManagerSettingsUpdated", {
      businessId = tostring(businessId),
      autoStartBackgroundRaces = (enabled == true),
    })
  end
  return true
end

M.onUpdate = onUpdate
M.hasManagerLevel1 = hasManagerLevel1
M.hasManagerLevel2 = hasManagerLevel2
M.sendDriverWithManager = racingTeamRaceSim.startBackgroundRace
M.cancelBackgroundRaceSim = racingTeamRaceSim.cancelBackgroundRace
M.tickScheduledRaceReadyToastsAccumulated = tickScheduledRaceReadyToastsAccumulated
M.tickHomeMechanicPwDeferredRechecks = racingTeamGoals.tickHomeMechanicPwDeferredRechecks
M.tickPostRaceCooldownDriverUiPushAccumulated = tickPostRaceCooldownDriverUiPushAccumulated
M.tickRacingTeamManagerAccumulated = tickRacingTeamManagerAccumulated
M.sanctionedOfferMatchesFleetVehicle = sanctionedOfferMatchesFleetVehicle
M.fleetVehicleOverpoweredForOffer = fleetVehicleOverpoweredForOffer
M.fleetVehicleEligibleForOffer = fleetVehicleEligibleForOffer
M.getRacingTeamPostRaceCooldownSeconds = getRacingTeamPostRaceCooldownSeconds
M.getRacingTeamDriverPostRaceCooldownRemainingSec = getRacingTeamDriverPostRaceCooldownRemainingSec
M.ensureSanctionedRaceOffersBoard = ensureRaceOfferBoard
M.getUIData = rtState.rtInternal.getUIData
M.getCurrentLeague = rtState.rtInternal.getCurrentLeague
M.isLeagueAtLeast = rtState.rtInternal.isLeagueAtLeast
M.isCurrentLeagueAtLeast = rtState.rtInternal.isCurrentLeagueAtLeast
M.getActiveGoals = function(businessId)
  local rows = getActiveGoalsList(businessId)
  return rows
end
M.getCompletedGoals = getCompletedGoalsList
M.getActiveJobs = getActiveJobs
M.getNewJobs = getNewJobs
M.acceptJob = acceptJob
M.declineJob = declineJob
M.abandonJob = abandonJob
M.sellVehicle = sellVehicle
M.acceptRacingTeamRaceOffer = acceptRacingTeamRaceOffer
M.acceptRacingTeamRaceOfferAsPlayer = acceptRacingTeamRaceOfferAsPlayer
M.listLeague1FleetVehiclesForSanctionedOffer = listLeague1FleetVehiclesForSanctionedOffer
M.listLeague2FleetVehiclesForSanctionedOffer = listLeague2FleetVehiclesForSanctionedOffer
M.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy = acceptRacingTeamRaceOfferAsPlayerAlongsideProxy
M.getFleetVehiclePostRaceCooldownRemainingSec = getFleetVehiclePostRaceCooldownRemainingSec
M.getPlayerPostRaceCooldownRemainingSec = getPlayerPostRaceCooldownRemainingSec
M.armPlayerPostRaceCooldown = armPlayerPostRaceCooldown
M.getRacingTeamPlayerPostRaceCooldownSeconds = getRacingTeamPlayerPostRaceCooldownSeconds
M.declineRacingTeamRaceOffer = declineRacingTeamRaceOffer
M.requestProxyDriverRace = function(opts)
  local flow = raceFlowMod()
  if flow and flow.requestProxyDriverRace then
    return flow.requestProxyDriverRace(opts)
  end
  return { ok = false, err = "no_proxy_flow" }
end
M.clearProxyDriverRaceRequest = clearProxyDriverRaceRequest
M.clearRacingTeamProxyDriverAssignment = clearRacingTeamProxyDriverAssignment
M.cancelUnarmedScheduledRacingTeamProxyRace = cancelUnarmedScheduledRacingTeamProxyRace
M.clearStuckRacingTeamProxyAfterTrackRaceCompletion = clearStuckRacingTeamProxyAfterTrackRaceCompletion
M.getProxyDriverRaceRequest = getProxyDriverRaceRequest
M.findProxyDriverRaceRequestForLevel = findProxyDriverRaceRequestForLevel
M.getBusinessXP = getRacingTeamBusinessSkillXpValue
M.addBusinessXP = addRacingTeamBusinessSkillXpValue
M.spendBusinessXP = spendRacingTeamBusinessSkillXpValue
M.settleProxySanctionedRaceFromAiResults = settleProxySanctionedRaceFromAiResults
M.onBusinessSanctionedRaceOutcome = onBusinessSanctionedRaceOutcome
M.notifyBusinessVehiclePartsPurchased = racingTeamGoals.notifyBusinessVehiclePartsPurchased
M.notifyTeamVehicleDynoPeakHp = racingTeamGoals.notifyTeamVehicleDynoPeakHp
M.notifyShortTrackStaminaLap = racingTeamGoals.notifyShortTrackStaminaLap
M.notifyOfficialSanctionedPodium = racingTeamGoals.notifyOfficialSanctionedPodium
M.isScheduledRaceReadyForDriver = isScheduledRaceReadyForDriver
M.assignJobToTech = assignJobToTech
M.assignFleetVehicleToDriver = assignFleetVehicleToDriver
M.updateTechName = updateTechName
M.fireTech = fireTech
M.hireTech = hireTech
M.stopTechFromJob = stopTechFromJob
M.requestFinancesData = racingTeamFinances.requestFinancesData
function M.applySanctionedRaceDriverCutFromBusinessPayout(businessId, grossAmount, opts)
  racingTeamFinances.applyDriverCutAfterPayout(businessId, grossAmount, opts or {})
end
M.acceptLeague2Invite = acceptLeague2Invite
M.declineLeague2Invite = declineLeague2Invite
M.racingTeamMilestoneLeague2Later = racingTeamMilestoneLeague2Later
M.racingTeamMilestoneLeague2Accept = racingTeamMilestoneLeague2Accept
M.racingTeamMilestoneLeague2WelcomeContinue = racingTeamMilestoneLeague2WelcomeContinue
M.racingTeamMilestonePurchaseContinue = racingTeamMilestonePurchaseContinue
M.racingTeamMilestoneCareerFinaleContinue = racingTeamMilestoneCareerFinaleContinue
M.assignRolledProxyRaceToDriver = assignRolledProxyRaceToDriver
M.acceptRacingTeamSponsorOffer = acceptRacingTeamSponsorOffer
M.declineRacingTeamSponsorOffer = declineRacingTeamSponsorOffer
M.dropRacingTeamSponsorActive = dropRacingTeamSponsorActive
M.getMaxPulledOutVehicles = getMaxPulledOutVehicles
M.getMaxActiveJobs = getMaxActiveJobs

function M.getCareerSimTimeForUI()
  return getCareerSimTime()
end

function M.tickScheduledRaceReadyToasts()
  processScheduledRaceReadyToastQueue()
end

local function isPendingRaceReadyDue(pending)
  if not pending then
    return false
  end
  local simDue = tonumber(pending.scheduledRaceSimTime)
  local wallDue = tonumber(pending.scheduledRaceReadyWallEpoch)
  local simReady = not simDue or getCareerSimTime() >= simDue
  local wallReady = wallDue and os.time() >= wallDue
  return simReady or wallReady
end

function M.notifyOnPhoneAppInstalled()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return
  end
  if not career_modules_business_businessManager or not career_modules_business_businessManager.getPurchasedBusinesses then
    return
  end
  local purchased = career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType)
  if not purchased then
    return
  end
  for bid, _ in pairs(purchased) do
    local businessId = normalizeBusinessId(bid)
    local changed = false
    for _, tech in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      local pending = tech.pendingRaceOffer
      if pending and isPendingRaceReadyDue(pending) and pending.raceReadyToastSent then
        pending.raceReadyToastSent = false
        changed = true
      end
    end
    if changed then
      racingTeamPersistDrivers(businessId)
      notifyRacingTeamDriversUpdated(businessId)
    end
  end
  processScheduledRaceReadyToastQueue()
end

function M.setRacingTeamManagerAutoAssign(businessId, enabled)
  if racingTeamManager and racingTeamManager.setManagerAutoAssignEnabled then
    return racingTeamManager.setManagerAutoAssignEnabled(businessId, enabled)
  end
  return false
end

function M.setRacingTeamManagerAssignInterval(businessId, intervalSec)
  if racingTeamManager and racingTeamManager.setManagerAssignIntervalSec then
    return racingTeamManager.setManagerAssignIntervalSec(businessId, intervalSec)
  end
  return false
end

function M.notifyFleetFromShop(businessId)
  if racingTeamBuildClass and racingTeamBuildClass.warmupCatalogBaselines then racingTeamBuildClass.warmupCatalogBaselines() end
  if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
    rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  end
  if rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer then
    rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

-- === Cross-sibling helper exposure
-- (Fleet/PW/cooldown/damage helpers live in racingTeamFleet and publish their
--  own rtInternal mirrors at require time.)
rtState.rtInternal.getOfferState = getOfferState
rtState.rtInternal.getCareerSimTime = getCareerSimTime
rtState.rtInternal.getRacingTeamLevelInfo = getRacingTeamLevelInfo
rtState.rtInternal.getRacingTeamLevelId = getRacingTeamLevelId
rtState.rtInternal.saveRacingTeamPersistedState = saveRacingTeamPersistedState
rtState.rtInternal.league2InvitePromoKey = league2InvitePromoKey
rtState.rtInternal.ensureRacingTeamDriverSlots = ensureRacingTeamDriverSlots
rtState.rtInternal.getRaceOfferBoard = getRaceOfferBoard
rtState.rtInternal.getMaxRaceOffersOnBoard = getMaxRaceOffersOnBoard
rtState.rtInternal.resolveRacingTeamLeaderboardLevelIds = resolveRacingTeamLeaderboardLevelIds
rtState.rtInternal.getSkillTreeNodeLevel = getSkillTreeNodeLevel
rtState.rtInternal.syncRacingTeamDriverUnlock = syncRacingTeamDriverUnlock

return M
