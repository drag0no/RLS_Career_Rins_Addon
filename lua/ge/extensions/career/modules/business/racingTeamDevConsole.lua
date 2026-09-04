local M = {}

local devConsole = require("ge/extensions/career/modules/devConsole")
require("ge/extensions/career/modules/business/racingTeamDevLog")
local rtState = require("ge/extensions/career/modules/business/racingTeamRuntimeState")
local racingTeamGoals = require("ge/extensions/career/modules/business/racingTeamGoals")
local racingTeamLeagueInvite = require("ge/extensions/career/modules/business/racingTeamLeagueInvite")
local racingTeamRaceOffers = require("ge/extensions/career/modules/business/racingTeamRaceOffers")
local racingTeamManager = require("ge/extensions/career/modules/business/racingTeamManager")

local BUSINESS_TYPE = "racingTeam"
local INJECT_MONEY_AMOUNT = 1000000
local INJECT_XP_AMOUNT = 20000

local function devLog()
  return rtState.rtInternal.devLog
end

local function logDev(businessId, level, message, source, context)
  local dl = devLog()
  if dl and dl.append then
    dl.append(businessId, level, message, source, context)
  end
end

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function ensureOfferState(businessId)
  local fn = rtState and rtState.rtInternal and rtState.rtInternal.getOfferState
  if type(fn) == "function" then
    return fn(businessId)
  end
end

local function guard()
  return devConsole.requireEnabled()
end

local function refreshUi(businessId)
  if rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer then
    rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  end
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

local function getHeadGoalId(businessId)
  local def = racingTeamGoals.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = racingTeamGoals.getSortedForLeague(def, leagueId)
  for _, g in ipairs(leagueGoals or {}) do
    if g and g.id and not racingTeamGoals.idCompleted(businessId, g.id) then
      return g.id
    end
  end
  return nil
end

local function skipDriverSchedulingWaits(tech)
  if type(tech) ~= "table" then
    return false
  end
  tech.racingCooldownUntilSimTime = nil
  tech.postRaceCooldownReadyWallEpoch = nil
  local pr = tech.pendingRaceOffer
  if type(pr) ~= "table" then
    return false
  end
  local nowSim = rtState.rtInternal.getCareerSimTime and rtState.rtInternal.getCareerSimTime() or 0
  pr.scheduledRaceSimTime = nowSim - 1
  pr.scheduledRaceReadyWallEpoch = os.time() - 1
  pr.raceReadyToastSent = false
  return true
end

function M.getDevLog(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  local dl = devLog()
  if dl and dl.scanIssues and businessId then
    dl.scanIssues(businessId)
  end
  local lines = dl and dl.getFormattedLines and dl.getFormattedLines() or {}
  return { ok = true, lines = lines }
end

function M.clearDevLog()
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  local dl = devLog()
  if dl and dl.clear then
    dl.clear()
  end
  return { ok = true }
end

function M.clearCooldowns(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local id = tostring(businessId)
  rtState.vehicleCooldownByBusiness[id] = {}
  rtState.playerCooldownByBusiness[id] = nil
  ensureOfferState(businessId)
  local scheduledReady = 0
  if rtState.businessDrivers[businessId] then
    for _, tech in ipairs(rtState.businessDrivers[businessId]) do
      if skipDriverSchedulingWaits(tech) then
        scheduledReady = scheduledReady + 1
      end
    end
  end
  local board = rtState.rtInternal.getRaceOfferBoard and rtState.rtInternal.getRaceOfferBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  if racingTeamManager and racingTeamManager.devSkipAssignWait then
    racingTeamManager.devSkipAssignWait(businessId)
  end
  local rt = rawget(_G, "career_modules_business_racingTeam")
  if rt and rt.tickScheduledRaceReadyToasts then
    pcall(rt.tickScheduledRaceReadyToasts)
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath and rtState.rtInternal.saveRacingTeamPersistedState then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  logDev(
    businessId,
    "info",
    string.format(
      "Skipped waits (cooldowns, %d scheduled race(s), manager booking timer, offer refresh)",
      scheduledReady
    ),
    "devConsole"
  )
  refreshUi(businessId)
  return { ok = true, scheduledReady = scheduledReady }
end

function M.refreshRaceOffers(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local board = rtState.rtInternal.getRaceOfferBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  racingTeamRaceOffers.topUp(businessId)
  logDev(businessId, "info", "Refreshed race offers", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.forceLeagueInvite(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  ensureOfferState(businessId)
  local currentLeague = rtState.rtInternal.getCurrentLeague(businessId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(currentLeague)
  if not nextLeague then
    logDev(businessId, "warn", "Force league invite: no next league", "devConsole")
    return { ok = false, error = "no_next_league" }
  end
  local inv = racingTeamLeagueInvite.getInviteTable(businessId)
  inv.offeredAt = rtState.rtInternal.getCareerSimTime()
  inv.targetLeague = nextLeague
  inv.declined = false
  rtState.league2InvitePromoUiByBusiness[tostring(businessId)] = "splash"
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath and rtState.rtInternal.saveRacingTeamPersistedState then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  logDev(businessId, "info", "Forced league invite to " .. tostring(nextLeague), "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.completeCurrentGoal(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local goalId = getHeadGoalId(businessId)
  if not goalId then
    logDev(businessId, "warn", "Complete current goal: none active", "devConsole")
    return { ok = false, error = "no_active_goal" }
  end
  racingTeamGoals.markGoalCompleted(businessId, goalId)
  logDev(businessId, "info", "Dev-completed goal " .. tostring(goalId), "devConsole")
  refreshUi(businessId)
  return { ok = true, goalId = goalId }
end

function M.completeAllLeagueGoals(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local def = racingTeamGoals.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = racingTeamGoals.getSortedForLeague(def, leagueId)
  local count = 0
  for _, g in ipairs(leagueGoals or {}) do
    if g and g.id and not racingTeamGoals.idCompleted(businessId, g.id) then
      racingTeamGoals.markGoalCompleted(businessId, g.id)
      count = count + 1
    end
  end
  logDev(businessId, "info", "Dev-completed " .. tostring(count) .. " league goals", "devConsole")
  refreshUi(businessId)
  return { ok = true, count = count }
end

function M.resetCurrentLeagueGoals(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  ensureOfferState(businessId)
  local id = tostring(businessId)
  local def = racingTeamGoals.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = racingTeamGoals.getSortedForLeague(def, leagueId)
  if not leagueGoals or #leagueGoals == 0 then
    logDev(businessId, "warn", "Reset current league: no goals for " .. tostring(leagueId), "devConsole")
    return { ok = false, error = "no_league_goals" }
  end

  rtState.goalCompletionByBusiness[id] = rtState.goalCompletionByBusiness[id] or {}
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  local cleared = 0
  local firstGoalId = nil
  for _, g in ipairs(leagueGoals) do
    if g and g.id then
      if not firstGoalId then
        firstGoalId = g.id
      end
      if rtState.goalCompletionByBusiness[id][g.id] then
        rtState.goalCompletionByBusiness[id][g.id] = nil
        cleared = cleared + 1
      end
      rtState.tuningMilestoneByGoalByBusiness[id][g.id] = nil
      if rtState.completedGoalLeaderboardTimesByBusiness[id] then
        rtState.completedGoalLeaderboardTimesByBusiness[id][g.id] = nil
      end
    end
  end
  if next(rtState.tuningMilestoneByGoalByBusiness[id]) == nil then
    rtState.tuningMilestoneByBusiness[id] = nil
  else
    rtState.tuningMilestoneByBusiness[id] = true
  end

  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(leagueId)
  if nextLeague then
    local inv = racingTeamLeagueInvite.getInviteTable(businessId)
    if inv.targetLeague == nextLeague then
      inv.offeredAt = nil
      inv.declined = false
      inv.targetLeague = nil
      rtState.league2InvitePromoUiByBusiness[id] = nil
    end
  end

  if leagueId == "league4" then
    rtState.careerFinaleSplashPendingByBusiness[id] = nil
    rtState.careerFinaleSplashShownByBusiness[id] = nil
    if rtState.rtInternal.careerFinaleSplashQueued then
      rtState.rtInternal.careerFinaleSplashQueued[id] = nil
    end
  end

  if rtState.rtInternal.refreshLeague2InviteOffer then
    rtState.rtInternal.refreshLeague2InviteOffer(businessId)
  end
  if rtState.rtInternal.syncRacingTeamDriverUnlock then
    rtState.rtInternal.syncRacingTeamDriverUnlock(businessId)
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath and rtState.rtInternal.saveRacingTeamPersistedState then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  logDev(
    businessId,
    "warn",
    string.format("Reset %s: cleared %d goal(s), active head %s", tostring(leagueId), cleared, tostring(firstGoalId)),
    "devConsole"
  )
  refreshUi(businessId)
  return { ok = true, leagueId = leagueId, cleared = cleared, firstGoalId = firstGoalId }
end

function M.maxAllSkills(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local st = career_modules_business_businessSkillTree
  if not st or not st.debugMaxAllNodes then
    return { ok = false, error = "skill_tree_unavailable" }
  end
  st.debugMaxAllNodes(BUSINESS_TYPE, businessId)
  logDev(businessId, "info", "Unlocked all skill nodes", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

local function resetBusinessBankToPurchaseState(businessId)
  if not career_modules_bank or not career_modules_bank.getBusinessAccount then
    return false, "bank_unavailable"
  end
  local account = career_modules_bank.getBusinessAccount(BUSINESS_TYPE, businessId)
  local accountId = account and (account.id or account.accountId)
  if not accountId then
    return false, "no_account"
  end
  local balance = math.floor(tonumber(account.balance) or 0)
  if balance > 0 and career_modules_bank.removeFunds then
    career_modules_bank.removeFunds(accountId, balance, "Dev Console", "Hard reset bank wipe")
  end
  if career_modules_business_businessManager and career_modules_business_businessManager.getPurchaseCapitalInjectionAmount then
    local capitalInjectionAmount = career_modules_business_businessManager.getPurchaseCapitalInjectionAmount(0)
    if capitalInjectionAmount > 0 and career_modules_bank.rewardToAccount then
      career_modules_bank.rewardToAccount({
        money = { amount = capitalInjectionAmount }
      }, accountId, "Dev Console", "Hard reset capital injection")
    end
  end
  return true
end

local function applySoftBusinessReset(businessId)
  local id = tostring(businessId)
  ensureOfferState(businessId)

  rtState.goalCompletionByBusiness[id] = {}
  rtState.tuningMilestoneByBusiness[id] = nil
  rtState.tuningMilestoneByGoalByBusiness[id] = {}
  rtState.homeMechanicBaselinePwByBusiness[id] = nil
  rtState.pendingHomeMechanicPwRecheckByBusiness[id] = nil
  rtState.allLeaderboardsBaselineByBusiness[id] = nil
  rtState.completedGoalLeaderboardTimesByBusiness[id] = nil
  rtState.staminaShortTrackStreakByBusiness[id] = nil
  rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] = nil

  rtState.currentLeagueByBusiness[id] = "league1"
  rtState.league2InviteByBusiness[id] = nil
  rtState.league2InvitePromoUiByBusiness[id] = nil
  rtState.raceUnlockSplashPendingByBusiness[id] = nil
  rtState.raceUnlockSplashShownByBusiness[id] = nil
  rtState.raceOfferBoardByBusiness[id] = nil
  rtState.pendingRematchOfferByBusiness[id] = nil

  local st = career_modules_business_businessSkillTree
  if st and st.clearBusinessProgress then
    st.clearBusinessProgress(businessId)
  end

  local board = rtState.rtInternal.getRaceOfferBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  racingTeamRaceOffers.topUp(businessId)
end

function M.resetBusinessSoft(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  applySoftBusinessReset(businessId)
  logDev(businessId, "warn", "Soft reset: goals, league, and skills (fleet and bank kept)", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.resetBusinessHard(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local businessObj = career_modules_business_businessManager
    and career_modules_business_businessManager.getBusinessObject(BUSINESS_TYPE)
  if not businessObj or not businessObj.resetBusinessForSale then
    return { ok = false, error = "reset_unavailable" }
  end
  if not businessObj.resetBusinessForSale(businessId) then
    return { ok = false, error = "reset_failed" }
  end
  local st = career_modules_business_businessSkillTree
  if st and st.clearBusinessProgress then
    st.clearBusinessProgress(businessId)
  end
  local bankOk, bankErr = resetBusinessBankToPurchaseState(businessId)
  if not bankOk then
    logDev(businessId, "error", "Hard reset bank: " .. tostring(bankErr), "devConsole")
    return { ok = false, error = bankErr }
  end
  if rtState.rtInternal.ensureRacingTeamDriverSlots then
    rtState.rtInternal.ensureRacingTeamDriverSlots(businessId)
  end
  if rtState.rtInternal.schedulePurchaseMilestoneSplash then
    rtState.rtInternal.schedulePurchaseMilestoneSplash(businessId)
  end
  if career_modules_business_businessComputer and career_modules_business_businessComputer.clearBusinessContext then
    career_modules_business_businessComputer.clearBusinessContext(businessId)
  end
  local board = rtState.rtInternal.getRaceOfferBoard(businessId)
  if board then
    board.nextRefreshAt = 0
  end
  racingTeamRaceOffers.topUp(businessId)
  logDev(businessId, "warn", "Hard reset: fleet, drivers, bank, goals, and skills wiped", "devConsole")
  refreshUi(businessId)
  return { ok = true }
end

function M.resetBusiness(businessId)
  return M.resetBusinessSoft(businessId)
end

function M.injectXp(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  local businessObj = career_modules_business_businessManager
    and career_modules_business_businessManager.getBusinessObject(BUSINESS_TYPE)
  if not businessObj or not businessObj.addBusinessXP then
    return { ok = false, error = "xp_unavailable" }
  end
  businessObj.addBusinessXP(businessId, INJECT_XP_AMOUNT)
  logDev(businessId, "info", "Injected " .. tostring(INJECT_XP_AMOUNT) .. " skill XP", "devConsole")
  if guihooks and guihooks.trigger then
    guihooks.trigger("businessSkillTree:onTreesUpdated", { businessId = businessId })
  end
  refreshUi(businessId)
  return { ok = true, amount = INJECT_XP_AMOUNT }
end

function M.injectMoney(businessId)
  local ok, err = guard()
  if not ok then
    return { ok = false, error = err }
  end
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { ok = false, error = "invalid_business" }
  end
  if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.rewardToAccount then
    return { ok = false, error = "bank_unavailable" }
  end
  local account = career_modules_bank.getBusinessAccount(BUSINESS_TYPE, businessId)
  local accountId = account and (account.id or account.accountId)
  if not accountId then
    return { ok = false, error = "no_account" }
  end
  local credited = career_modules_bank.rewardToAccount({
    money = { amount = INJECT_MONEY_AMOUNT }
  }, accountId, "Dev Console", "Inject money")
  if not credited then
    logDev(businessId, "error", "Inject money failed", "devConsole")
    return { ok = false, error = "credit_failed" }
  end
  logDev(businessId, "info", "Injected $" .. tostring(INJECT_MONEY_AMOUNT), "devConsole")
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return { ok = true }
end

return M
