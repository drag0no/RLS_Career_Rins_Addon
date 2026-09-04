local M = {}

local rtState = require('ge/extensions/career/modules/business/racingTeamRuntimeState')

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

local function promoKey(businessId)
  return tostring(normalizeBusinessId(businessId))
end

local function devLog(businessId, level, message)
  local dl = rtState.rtInternal.devLog
  if dl and dl.append then
    dl.append(businessId, level, message, "leagueInvite")
  end
end

function M.getInviteTable(businessId)
  local id = promoKey(businessId)
  if not rtState.league2InviteByBusiness[id] then
    rtState.league2InviteByBusiness[id] = { offeredAt = nil, declined = false, targetLeague = nil }
  end
  return rtState.league2InviteByBusiness[id]
end

-- === Per-target invite config lookup
rtState.rtInternal.getLeagueInviteConfigForTarget = function(lvInf, targetLeague)
  local n = tonumber(string.match(tostring(targetLeague or ""), "^league(%d+)$"))
  if not n or n < 2 or n > 4 then
    n = 2
  end
  return {
    targetLeague = "league" .. n,
    orgName = lvInf[string.format("league%dInviteOrgName", n)],
    acronym = lvInf[string.format("league%dInviteAcronym", n)],
    feeEarly = tonumber(lvInf[string.format("league%dInviteFeeEarly", n)]) or 1500,
    feeLate = tonumber(lvInf[string.format("league%dInviteFeeLate", n)]) or 2500,
    feeEscalateMinutes = tonumber(lvInf[string.format("league%dInviteFeeEscalateMinutes", n)]) or 60,
    bankReasonShort = lvInf[string.format("league%dBankReasonShort", n)],
    splashTitle = lvInf[string.format("splashLeague%dTitle", n)],
    splashBody = lvInf[string.format("splashLeague%dBody", n)],
    splashAcceptLabel = lvInf[string.format("splashLeague%dAcceptLabel", n)],
    splashLaterLabel = lvInf[string.format("splashLeague%dLaterLabel", n)],
    splashImageUrl = lvInf[string.format("splashLeague%dImageUrl", n)],
    welcomeTitle = lvInf[string.format("splashLeague%dWelcomeTitle", n)],
    welcomeBody = lvInf[string.format("splashLeague%dWelcomeBody", n)],
    welcomeContinueLabel = lvInf[string.format("splashLeague%dWelcomeContinueLabel", n)],
    welcomeImageUrl = lvInf[string.format("splashLeague%dWelcomeImageUrl", n)],
    msgWelcome = lvInf[string.format("msgWelcomeLeague%d", n)],
  }
end

-- === League promotion ladder
rtState.rtInternal.LEAGUE_PROMOTION_NEXT = {
  league1 = "league2",
  league2 = "league3",
  league3 = "league4",
}

rtState.rtInternal.getNextLeagueForPromotion = function(currentLeague)
  return rtState.rtInternal.LEAGUE_PROMOTION_NEXT[tostring(currentLeague or "")]
end

local function debitAccount(businessId, amount, reason, description)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.removeFunds then
    return false
  end
  local account = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
  if not account then
    return false
  end
  local accountId = account.id or account.accountId
  if not accountId then
    return false
  end
  local r = reason
  if not r or r == "" then
    local inf = rtState.rtInternal.getRacingTeamLevelInfo(rtState.rtInternal.getRacingTeamLevelId())
    r = (inf.league2BankReasonShort and inf.league2BankReasonShort ~= "" and inf.league2BankReasonShort)
      or inf.league2InviteAcronym
      or "Racing team"
  end
  return career_modules_bank.removeFunds(accountId, amount, r, "", description or "", true)
end

function M.feeAmount(businessId)
  local inv = M.getInviteTable(businessId)
  local inf = rtState.rtInternal.getRacingTeamLevelInfo(rtState.rtInternal.getRacingTeamLevelId())
  local cfg = rtState.rtInternal.getLeagueInviteConfigForTarget(inf, inv.targetLeague or "league2")
  local offeredAt = tonumber(inv.offeredAt)
  if not offeredAt then
    return cfg.feeEarly
  end
  local now = rtState.rtInternal.getCareerSimTime()
  if (now - offeredAt) >= cfg.feeEscalateMinutes then
    return cfg.feeLate
  end
  return cfg.feeEarly
end

rtState.rtInternal.triggerRacingTeamMilestoneSplashShow = function(businessId, kind, opts)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not guihooks or not guihooks.trigger then
    return
  end
  local lvInf = rtState.rtInternal.getRacingTeamLevelInfo(rtState.rtInternal.getRacingTeamLevelId())
  if kind == "league2_welcome" then
    if simTimeAuthority and simTimeAuthority.pause then
      simTimeAuthority.pause(true)
    end
    local target = (opts and opts.targetLeague) or "league2"
    local cfg = rtState.rtInternal.getLeagueInviteConfigForTarget(lvInf, target)
    guihooks.trigger("RacingTeamMilestoneSplashShow", {
      {
        kind = "league2_welcome",
        businessId = businessId,
        targetLeague = cfg.targetLeague,
        title = cfg.welcomeTitle,
        body = cfg.welcomeBody,
        continueLabel = cfg.welcomeContinueLabel,
        imageUrl = cfg.welcomeImageUrl,
      },
    })
  elseif kind == "purchase" then
    guihooks.trigger("RacingTeamMilestoneSplashShow", {
      {
        kind = "purchase",
        businessId = businessId,
        title = lvInf.splashPurchaseTitle,
        body = lvInf.splashPurchaseBody,
        continueLabel = lvInf.splashPurchaseContinueLabel,
        imageUrl = lvInf.splashPurchaseImageUrl,
      },
    })
  elseif kind == "race_unlock" then
    guihooks.trigger("RacingTeamMilestoneSplashShow", {
      {
        kind = "race_unlock",
        businessId = businessId,
        title = "Congratulations!",
        body = "You have unlocked races.",
        continueLabel = "Continue",
      },
    })
  elseif kind == "career_finale" then
    if simTimeAuthority and simTimeAuthority.pause then
      simTimeAuthority.pause(true)
    end
    guihooks.trigger("RacingTeamMilestoneSplashShow", {
      {
        kind = "career_finale",
        businessId = businessId,
        title = lvInf.splashCareerFinaleTitle,
        body = lvInf.splashCareerFinaleBody,
        continueLabel = lvInf.splashCareerFinaleContinueLabel,
        imageUrl = lvInf.splashCareerFinaleImageUrl,
      },
    })
  end
end

rtState.rtInternal.scheduleCareerFinaleSplash = function(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local id = tostring(businessId)
  if rtState.careerFinaleSplashShownByBusiness[id] then
    return
  end
  if rtState.rtInternal.careerFinaleSplashQueued and rtState.rtInternal.careerFinaleSplashQueued[id] then
    return
  end
  rtState.rtInternal.careerFinaleSplashQueued = rtState.rtInternal.careerFinaleSplashQueued or {}
  rtState.rtInternal.careerFinaleSplashQueued[id] = true
  if not core_jobsystem or not core_jobsystem.create then
    rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "career_finale")
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "career_finale")
  end)
end

rtState.rtInternal.scheduleLeague2WelcomeSplash = function(businessId, targetLeague)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local id = tostring(businessId)
  if rtState.rtInternal.league2SplashQueued[id] then
    return
  end
  rtState.rtInternal.league2SplashQueued[id] = true
  local opts = { targetLeague = targetLeague or "league2" }
  if not core_jobsystem or not core_jobsystem.create then
    rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "league2_welcome", opts)
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(0.35)
    rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "league2_welcome", opts)
  end)
end

rtState.rtInternal.schedulePurchaseMilestoneSplash = function(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local id = tostring(businessId)
  if rtState.purchaseMilestoneSplashShownByBusiness[id] then
    return
  end
  if rtState.rtInternal.purchaseSplashQueued[id] then
    return
  end
  rtState.rtInternal.purchaseSplashQueued[id] = true
  if not core_jobsystem or not core_jobsystem.create then
    rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "purchase")
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(0.5)
    rtState.rtInternal.triggerRacingTeamMilestoneSplashShow(businessId, "purchase")
  end)
end

local function clearRaceBoardOnPromotion(businessId)
  local board = rtState.rtInternal.getRaceOfferBoard(businessId)
  if not board then return end
  board.offers = {}
  board.nextRefreshAt = 0
end

rtState.rtInternal.refreshLeague2InviteOffer = function(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  rtState.rtInternal.getOfferState(businessId)
  local currentLeague = rtState.rtInternal.getCurrentLeague(businessId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(currentLeague)
  if not nextLeague then
    return
  end
  local inv = M.getInviteTable(businessId)
  -- Stale invite from a prior league? Clear so we don't show wrong copy/fee.
  if inv.offeredAt and inv.targetLeague and inv.targetLeague ~= nextLeague then
    inv.offeredAt = nil
    inv.declined = false
    inv.targetLeague = nil
    rtState.league2InvitePromoUiByBusiness[promoKey(businessId)] = nil
  end
  if inv.declined then
    return
  end
  if not rtState.rtInternal.allGoalsCompleteForLeague(businessId, currentLeague) then
    return
  end
  if inv.offeredAt == nil then
    inv.offeredAt = rtState.rtInternal.getCareerSimTime()
    inv.targetLeague = nextLeague
    rtState.league2InvitePromoUiByBusiness[promoKey(businessId)] = "splash"
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
    end
  end
end

function M.accept(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    devLog(businessId, "warn", "Accept invite: invalid business")
    return false, "invalid_business"
  end
  rtState.rtInternal.getOfferState(businessId)
  local currentLeague = rtState.rtInternal.getCurrentLeague(businessId)
  local nextLeague = rtState.rtInternal.getNextLeagueForPromotion(currentLeague)
  if not nextLeague then
    devLog(businessId, "warn", "Accept invite: no next league")
    return false, "no_next_league"
  end
  local inv = M.getInviteTable(businessId)
  if inv.declined then
    devLog(businessId, "warn", "Accept invite: previously declined")
    return false, "declined"
  end
  if not inv.offeredAt then
    rtState.rtInternal.refreshLeague2InviteOffer(businessId)
  end
  if not inv.offeredAt then
    devLog(businessId, "warn", "Accept invite: not offered")
    return false, "not_offered"
  end
  local target = inv.targetLeague or nextLeague
  if target ~= nextLeague then
    devLog(businessId, "warn", "Accept invite: target mismatch " .. tostring(target) .. " vs " .. tostring(nextLeague))
    return false, "target_mismatch"
  end
  local fee = M.feeAmount(businessId)
  local lvInf = rtState.rtInternal.getRacingTeamLevelInfo(rtState.rtInternal.getRacingTeamLevelId())
  local cfg = rtState.rtInternal.getLeagueInviteConfigForTarget(lvInf, target)
  local ac = cfg.acronym or "Racing"
  local org = cfg.orgName or "Racing Association"
  local bankReason = (cfg.bankReasonShort and cfg.bankReasonShort ~= "") and cfg.bankReasonShort or (ac .. " membership")
  if not debitAccount(
      businessId,
      fee,
      bankReason,
      org .. " — league registration"
    ) then
    devLog(businessId, "warn", "Accept invite: insufficient funds for fee " .. tostring(fee))
    return false, "insufficient_funds"
  end
  local id = promoKey(businessId)
  rtState.currentLeagueByBusiness[id] = target
  rtState.league2InvitePromoUiByBusiness[id] = nil
  rtState.league2InviteByBusiness[id] = { offeredAt = nil, declined = false, targetLeague = nil }
  clearRaceBoardOnPromotion(businessId)
  if rtState.rtInternal.ensureRacingTeamDriverSlots then
    rtState.rtInternal.ensureRacingTeamDriverSlots(businessId)
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  if ui_message then
    local toastTitle = (target == "league2") and (lvInf.msgWelcomeToastTitle or ac) or ac
    ui_message(
      cfg.msgWelcome or ("Welcome to " .. ac),
      8,
      toastTitle,
      "info"
    )
  end
  if rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer then
    rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  end
  rtState.rtInternal.scheduleLeague2WelcomeSplash(businessId, target)
  devLog(businessId, "info", "Promoted to " .. tostring(target))
  return true, nil
end

function M.decline(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  rtState.rtInternal.getOfferState(businessId)
  local inv = M.getInviteTable(businessId)
  inv.declined = true
  devLog(businessId, "info", "Declined league invite to " .. tostring(inv.targetLeague))
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

local function unpauseMilestoneSim()
  if simTimeAuthority and simTimeAuthority.pause then
    simTimeAuthority.pause(false)
  end
end

function M.milestoneLeague2Later(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  rtState.league2InvitePromoUiByBusiness[promoKey(businessId)] = "jobs"
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  if rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer then
    rtState.rtInternal.pushRacingTeamGoalsToBusinessComputer(businessId)
  end
  return true
end

function M.milestoneLeague2WelcomeContinue(businessId)
  unpauseMilestoneSim()
  local id = tostring(normalizeBusinessId(businessId))
  rtState.rtInternal.league2SplashQueued[id] = false
  return true
end

function M.milestoneLeague2Accept(businessId)
  return M.accept(businessId)
end

function M.milestoneCareerFinaleContinue(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  unpauseMilestoneSim()
  local id = tostring(businessId)
  rtState.careerFinaleSplashShownByBusiness[id] = true
  rtState.careerFinaleSplashPendingByBusiness[id] = false
  if rtState.rtInternal.careerFinaleSplashQueued then
    rtState.rtInternal.careerFinaleSplashQueued[id] = nil
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

function M.milestonePurchaseContinue(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  rtState.purchaseMilestoneSplashShownByBusiness[tostring(businessId)] = true
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

return M
