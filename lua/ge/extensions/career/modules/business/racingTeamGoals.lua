local M = {}

local rtState = require('ge/extensions/career/modules/business/racingTeamRuntimeState')
local racingTeamRaceOffers = require('ge/extensions/career/modules/business/racingTeamRaceOffers')

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

local HOME_MECHANIC_GOAL_ID = "rt_t1_g3"
local RT_T2_G4_TUNING_GOAL_ID = "rt_t2_g4"
local RT_T2_G6_TUNING_GOAL_ID = "rt_t2_g6"
local RT_T3_G3_TUNING_GOAL_ID = "rt_t3_g3"
local TIER3_DYNO_MIN_HP = 600
local BRACKET_NEAR_TOP_FRACTION = 0.25
local BRACKET_NEAR_TOP_MIN = 0.012

function M.loadDefinition()
  if rtState.rtInternal.goalsDefinitionLoaded then
    return rtState.rtInternal.goalsDefinition
  end
  rtState.rtInternal.goalsDefinitionLoaded = true
  if not FS or not FS.fileExists or not FS:fileExists(rtState.K.RACING_TEAM_GOALS_PATH) then
    rtState.rtInternal.goalsDefinition = nil
    return nil
  end
  rtState.rtInternal.goalsDefinition = jsonReadFile(rtState.K.RACING_TEAM_GOALS_PATH)
  return rtState.rtInternal.goalsDefinition
end

function M.resolvedLeague(g)
  if not g then
    return "league1"
  end
  if type(g.league) == "string" and g.league ~= "" then
    return g.league
  end
  local t = tonumber(g.tier)
  if t and t >= 1 then
    return "league" .. tostring(math.floor(t))
  end
  return "league1"
end

local function leagueRankSortKey(leagueId)
  local n = tonumber(string.match(tostring(leagueId or ""), "^league(%d+)$"))
  return n or 99
end

local function leagueStuckCapProgressLabel(leagueId)
  local n = tonumber(string.match(tostring(leagueId or ""), "^league(%d+)$"))
  if n == 4 then
    return "Career complete"
  end
  if n then
    return string.format("League complete — League %d coming soon.", n + 1)
  end
  return "League complete"
end

function M.getSortedForLeague(def, leagueId)
  local out = {}
  if not def or type(def.goals) ~= "table" then
    return out
  end
  for _, g in ipairs(def.goals) do
    if M.resolvedLeague(g) == leagueId then
      table.insert(out, g)
    end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
  end)
  return out
end

function M.formatRaceTime(seconds)
  if not seconds or seconds <= 0 then
    return "--"
  end
  if utils and utils.formatTime then
    return utils.formatTime(seconds)
  end
  return string.format("%.2f s", seconds)
end

function M.idCompleted(businessId, goalId)
  local id = tostring(normalizeBusinessId(businessId))
  local m = rtState.goalCompletionByBusiness[id]
  return m and m[goalId] == true
end

function M.tuningMilestonePreDoneForGoal(businessId, goalIdStr)
  local id = tostring(normalizeBusinessId(businessId))
  local m = rtState.tuningMilestoneByGoalByBusiness[id]
  return m and m[goalIdStr] == true
end

function M.setTuningMilestoneGoalPreDone(businessId, goalIdStr)
  local bid = normalizeBusinessId(businessId)
  local id = tostring(bid)
  rtState.tuningMilestoneByGoalByBusiness[id] = rtState.tuningMilestoneByGoalByBusiness[id] or {}
  if rtState.tuningMilestoneByGoalByBusiness[id][goalIdStr] then
    return
  end
  rtState.tuningMilestoneByGoalByBusiness[id][goalIdStr] = true
  local m = rtState.tuningMilestoneByGoalByBusiness[id]
  rtState.tuningMilestoneByBusiness[id] = next(m) ~= nil
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(bid, savePath)
  end
  if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
    rtState.rtInternal.advanceRacingTeamGoalsIfReady(bid)
  end
end

-- === Leaderboard helpers
function M.getPrimaryLeaderboardVehicleId(businessId)
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessVehicles then
    return nil
  end
  local vehicles = inv.getBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    if vehicle and vehicle.vehicleId ~= nil then
      return tonumber(vehicle.vehicleId) or vehicle.vehicleId
    end
  end
  return nil
end

local function hasBusinessVehicle(businessId)
  return M.getPrimaryLeaderboardVehicleId(businessId) ~= nil
end

local function getBestTimeForBusinessVehicle(businessId, vehicleId, raceType, raceLabel)
  if not career_modules_business_businessHelpers or not career_modules_business_businessHelpers.getBestLeaderboardTime then
    return nil
  end
  return career_modules_business_businessHelpers.getBestLeaderboardTime(businessId, vehicleId, raceType, raceLabel,
      rtState.rtInternal.resolveRacingTeamLeaderboardLevelIds())
end

local function getBestTimeAcrossAllTeamJobs(businessId, raceType, raceLabel)
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessVehicles then
    return nil
  end
  local best = nil
  local vehicles = inv.getBusinessVehicles(businessId) or {}
  for _, vehicle in ipairs(vehicles) do
    local vid = vehicle and (tonumber(vehicle.vehicleId) or vehicle.vehicleId)
    if vid ~= nil then
      local t = getBestTimeForBusinessVehicle(businessId, vid, raceType, raceLabel)
      if t and t > 0 and (not best or t < best) then
          best = t
      end
    end
  end
  return best
end

local function snapshotCompletedGoalLeaderboardTimesAtCompletion(businessId, goalId)
  if not goalId then
    return
  end
  local def = M.loadDefinition()
  if not def or type(def.goals) ~= "table" then
    return
  end
  local g = nil
  for _, gg in ipairs(def.goals) do
    if gg and gg.id == goalId then
      g = gg
      break
    end
  end
  if not g then
    return
  end
  local kind = g.kind or ""
  local id = tostring(normalizeBusinessId(businessId))
  rtState.completedGoalLeaderboardTimesByBusiness[id] = rtState.completedGoalLeaderboardTimesByBusiness[id] or {}
  if kind == "vehicle_and_leaderboard" then
    local rt, rl = g.raceType, g.raceLabel
    if rt and rl then
      local best = getBestTimeAcrossAllTeamJobs(businessId, rt, rl)
      rtState.completedGoalLeaderboardTimesByBusiness[id][goalId] = {
        kind = "single",
        bestSec = best,
      }
    end
  elseif kind == "all_leaderboards" and type(g.tracks) == "table" then
    local rows = {}
    for _, tr in ipairs(g.tracks) do
      local rt, rl = tr.raceType, tr.raceLabel
      local t = nil
      if rt and rl then
        t = getBestTimeAcrossAllTeamJobs(businessId, rt, rl)
      end
      table.insert(rows, { raceType = rt, raceLabel = rl, bestSec = t })
    end
    rtState.completedGoalLeaderboardTimesByBusiness[id][goalId] = {
      kind = "tracks",
      tracks = rows,
    }
  end
end

-- === Baseline tracking for all_leaderboards goals
do
  local function findGoalInDefinition(goalId)
    local def = M.loadDefinition()
    if not def or type(def.goals) ~= "table" then
      return nil
    end
    for _, gg in ipairs(def.goals) do
      if gg and gg.id == goalId then
        return gg
      end
    end
    return nil
  end

  local function recordAllLeaderboardsBaselinesForGoal(businessId, goalIdWithAllLeaderboards)
    local g = findGoalInDefinition(goalIdWithAllLeaderboards)
    if not g or (g.kind or "") ~= "all_leaderboards" or type(g.tracks) ~= "table" then
      return
    end
    local id = tostring(normalizeBusinessId(businessId))
    local entries = {}
    for _, tr in ipairs(g.tracks) do
      local rt, rl = tr.raceType, tr.raceLabel
      local best = nil
      if rt and rl then
        best = getBestTimeAcrossAllTeamJobs(businessId, rt, rl)
      end
      table.insert(entries, { raceType = rt, raceLabel = rl, baselineSec = best })
    end
    rtState.allLeaderboardsBaselineByBusiness[id] = rtState.allLeaderboardsBaselineByBusiness[id] or {}
    rtState.allLeaderboardsBaselineByBusiness[id][goalIdWithAllLeaderboards] = entries
  end

  function rtState.rtInternal.recordBaselinesAfterCompletedPrerequisite(businessId, completedGoalId)
    local def = M.loadDefinition()
    if not def or type(def.goals) ~= "table" then
      return
    end
    for _, gg in ipairs(def.goals) do
      if gg and (gg.kind or "") == "all_leaderboards" and type(gg.baselineAfterGoalId) == "string"
          and gg.baselineAfterGoalId == completedGoalId and type(gg.id) == "string" then
        recordAllLeaderboardsBaselinesForGoal(businessId, gg.id)
      end
    end
  end

  function rtState.rtInternal.ensureAllLeaderboardsBaselineForGoal(businessId, g)
    local prereq = g.baselineAfterGoalId
    if type(prereq) ~= "string" then
      return nil
    end
    if not M.idCompleted(businessId, prereq) then
      return nil
    end
    local id = tostring(normalizeBusinessId(businessId))
    rtState.allLeaderboardsBaselineByBusiness[id] = rtState.allLeaderboardsBaselineByBusiness[id] or {}
    local ent = rtState.allLeaderboardsBaselineByBusiness[id][g.id]
    if not ent or #ent == 0 then
      recordAllLeaderboardsBaselinesForGoal(businessId, g.id)
      local _, savePath = career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
      end
      ent = rtState.allLeaderboardsBaselineByBusiness[id][g.id]
    end
    return ent
  end
end

-- === Stamina / podium counters
function rtState.rtInternal.getStaminaStreak(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return rtState.staminaShortTrackStreakByBusiness[id] or 0
end

function rtState.rtInternal.setStaminaStreak(businessId, n)
  local id = tostring(normalizeBusinessId(businessId))
  rtState.staminaShortTrackStreakByBusiness[id] = math.max(0, math.floor(n))
end

local function getLeagueHeadGoalId(businessId, def, leagueId)
  if not def or type(def.goals) ~= "table" then
    return nil
  end
  local leagueGoals = M.getSortedForLeague(def, leagueId)
  if type(leagueGoals) ~= "table" then
    return nil
  end
  for _, g in ipairs(leagueGoals) do
    if g and g.id and not M.idCompleted(businessId, g.id) then
      return g.id
    end
  end
  return nil
end

-- --- Stamina streak reset when head goal is rt_t1_g4 (GOAL_UNLOCK_SANCTIONED_RACE_OFFERS)
local function resetStaminaStreakIfStaminaGoalIsHead(businessId)
  local def = M.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local headId = getLeagueHeadGoalId(businessId, def, leagueId)
  if headId == rtState.K.GOAL_UNLOCK_SANCTIONED_RACE_OFFERS then
    rtState.rtInternal.setStaminaStreak(businessId, 0)
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
    end
  end
end

function rtState.rtInternal.getSanctionedOfficialFirstPlaceWins(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return rtState.sanctionedOfficialFirstPlaceWinsByBusiness[id] or 0
end

-- === Business / fleet helpers used by goal evaluation
local function racingTeamOfferMatchesBusiness(businessId, offer)
  if type(offer) ~= "table" or offer.racingTeamBusinessOffer ~= true then
    return false
  end
  local ob = offer.businessId
  if ob == nil then
    return false
  end
  return tostring(normalizeBusinessId(ob)) == tostring(normalizeBusinessId(businessId))
end

local function isPurchasedRacingTeamBusiness(purchased, bid)
  if type(purchased) ~= "table" or bid == nil then
    return false
  end
  local want = tostring(normalizeBusinessId(bid))
  for k, _ in pairs(purchased) do
    if tostring(normalizeBusinessId(k)) == want then
      return true
    end
  end
  return false
end

local function getBusinessOperatingEarningsTotal(businessId)
  local bank = career_modules_bank
  if not bank or not bank.getBusinessAccount or not bank.getAccountTransactions then
    return nil
  end
  local acct = bank.getBusinessAccount(rtState.businessType, businessId)
  if not acct or not acct.id then
    return nil
  end
  local t0 = tonumber(acct.createdAt) or 0
  local list = bank.getAccountTransactions(acct.id, nil) or {}
  local sum = 0
  for _, tr in ipairs(list) do
    local amt = tonumber(tr.amount) or 0
    if amt > 0 then
      local ts = tonumber(tr.timestamp) or 0
      if ts >= t0 then
        local lab = tostring(tr.label or "")
        if lab ~= "Capital Injection" and lab ~= "Transfer In" and lab ~= "Transfer Refund" then
          sum = sum + amt
        end
      end
    end
  end
  return math.floor(sum + 0.5)
end

local function countFleetSanctionedBranch(businessId, wantBranch)
  local want = string.lower(tostring(wantBranch or ""))
  if want == "" then
    return 0
  end
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return 0
  end
  local n = 0
  for _, v in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
    local br = rtState.rtInternal.resolveFleetVehicleSanctionedBranch(businessId, v)
    if type(br) == "string" and string.lower(br) == want then
      n = n + 1
    end
  end
  return n
end

local function fleetHasSuperBranchVehicle(businessId)
  return countFleetSanctionedBranch(businessId, "super") > 0
end

local function maxFleetDynoPeakHp(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  local peaks = rtState.classOptimizationPeakHpByBusiness[id]
  if type(peaks) ~= "table" then
    return 0
  end
  local best = 0
  for _, e in pairs(peaks) do
    local hp = type(e) == "table" and tonumber(e.hp) or tonumber(e)
    if hp and hp > best then
      best = hp
    end
  end
  return best
end

local function fleetHasVehicleInSanctionedBracket(businessId, bracketId)
  local sr = gameplay_events_freContracts_sanctionedRacing
  local b = sr and sr.getSanctionedPwBracketById and sr.getSanctionedPwBracketById(bracketId)
  if not b then
    return false
  end
  local lo = tonumber(b.classPwMin) or 0
  local hi = tonumber(b.classPwMax) or 0
  if hi < lo then
    lo, hi = hi, lo
  end
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return false
  end
  for _, v in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
    local pw = rtState.rtInternal.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and pw >= lo and pw <= hi + 1e-4 then
      return true
    end
  end
  return false
end

local function fleetHasVehicleNearSanctionedBracketTop(businessId, bracketId)
  local sr = gameplay_events_freContracts_sanctionedRacing
  local b = sr and sr.getSanctionedPwBracketById and sr.getSanctionedPwBracketById(bracketId)
  if not b then
    return false
  end
  local lo = tonumber(b.classPwMin) or 0
  local hi = math.max(tonumber(b.classPwMax) or 0, lo)
  local span = hi - lo
  local margin = math.max(BRACKET_NEAR_TOP_MIN, span * BRACKET_NEAR_TOP_FRACTION)
  local floorPw = hi - margin
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return false
  end
  for _, v in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
    local pw = rtState.rtInternal.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and pw >= floorPw and pw <= hi + 1e-4 then
      return true
    end
  end
  return false
end

local function maybeCompleteHomeMechanicFromFleetPw(businessId)
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return
  end
  local id = tostring(bid)
  if M.tuningMilestonePreDoneForGoal(bid, HOME_MECHANIC_GOAL_ID) then
    return
  end
  if M.idCompleted(bid, HOME_MECHANIC_GOAL_ID) then
    return
  end
  if not hasBusinessVehicle(bid) then
    return
  end
  local cur = rtState.rtInternal.getBestTeamJobVehiclePw(bid)
  if not cur or cur <= 0 then
    return
  end
  local base = rtState.homeMechanicBaselinePwByBusiness[id]
  if base == nil then
    rtState.homeMechanicBaselinePwByBusiness[id] = cur
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.rtInternal.saveRacingTeamPersistedState(bid, savePath)
    end
    return
  end
  if cur > base + 1e-5 then
    M.setTuningMilestoneGoalPreDone(bid, HOME_MECHANIC_GOAL_ID)
  end
end

local function scheduleHomeMechanicPwRecheckAfterParts(businessId)
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return
  end
  rtState.pendingHomeMechanicPwRecheckByBusiness[tostring(bid)] = true
end

function M.tickHomeMechanicPwDeferredRechecks()
  local pend = rtState.pendingHomeMechanicPwRecheckByBusiness
  if not pend or not next(pend) then
    return
  end
  local bids = {}
  for idStr, _ in pairs(pend) do
    pend[idStr] = nil
    table.insert(bids, tonumber(idStr) or idStr)
  end
  for _, bid in ipairs(bids) do
    maybeCompleteHomeMechanicFromFleetPw(bid)
  end
end

-- === Per-goal progress evaluator
function M.evaluateGoalProgress(businessId, g)
  local kind = g.kind or "placeholder"
  if kind == "placeholder" then
    return false, g.progressLabel or "Coming soon"
  end
  if kind == "tier_cap" then
    return true, g.progressDone or g.progressLabel or "Complete"
  end

  if kind == "sanctioned_podium" then
    if M.idCompleted(businessId, g.id) then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, g.progressNoPodium or g.progressLabel or "Place 1st–3rd in a sanctioned race"
  end

  if kind == "financial_milestone" then
    local target = tonumber(g.targetAmount) or 15000
    if target <= 0 then
      target = 15000
    end
    local earned = getBusinessOperatingEarningsTotal(businessId)
    if earned == nil then
      return false, g.progressLabel or "Bank or business account unavailable"
    end
    if earned >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Earnings: $%d / $%d", earned, math.floor(target))
  end

  if kind == "management_action" then
    local target = tonumber(g.targetDriverCount)
    if not target or target < 1 then
      target = 1
    end
    local count = 0
    for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if t and not t.fired then
        count = count + 1
      end
    end
    if count >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    if target <= 1 then
      return false, g.progressLabel or "Driver not hired"
    end
    return false, string.format("Drivers: %d/%d", count, target)
  end

  if kind == "fleet_size" then
    local target = tonumber(g.targetFleetCount) or 2
    if target < 1 then
      target = 2
    end
    local bidStr = tostring(g.hpBracketId or "")
    if bidStr == "" then
      return false, g.progressLabel or "Not configured"
    end
    local sr = gameplay_events_freContracts_sanctionedRacing
    local bracket = sr and sr.getSanctionedPwBracketById and sr.getSanctionedPwBracketById(bidStr)
    if not bracket then
      return false, g.progressLabel or "Unknown class bracket"
    end
    local fb = g.fleetBranch
    if type(fb) == "string" and fb ~= "" then
      if string.lower(tostring(bracket.branch or "")) ~= string.lower(fb) then
        return false, g.progressLabel or "Bracket mismatch"
      end
    end
    local lo = tonumber(bracket.classPwMin) or 0
    local hi = tonumber(bracket.classPwMax) or 0
    if hi < lo then
      lo, hi = hi, lo
    end
    if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
      return false, g.progressLabel or "Inventory unavailable"
    end
    local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
    local count = 0
    for _, v in ipairs(vehicles) do
      local pw = rtState.rtInternal.getEffectiveTeamJobVehiclePw(businessId, v)
      if pw and pw >= lo and pw <= hi then
        count = count + 1
      end
    end
    if count >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    local label = bracket.label or bidStr
    return false, string.format("Vehicles: %d/%d (%s)", count, target, label)
  end

  if kind == "ai_race_results" then
    local target = tonumber(g.targetPodiums) or 5
    if target < 1 then
      target = 5
    end
    local total = 0
    for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if t and not t.fired then
        total = total + math.max(0, math.floor(tonumber(t.sanctionedPodiums) or 0))
      end
    end
    if total >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Podiums: %d/%d", total, target)
  end

  if kind == "race_participation" then
    local target = tonumber(g.targetRaces) or 10
    if target < 1 then
      target = 10
    end
    local total = 0
    for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if t and not t.fired then
        total = total + math.max(0, math.floor(tonumber(t.sanctionedRacesFinished) or 0))
      end
    end
    if total >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Races finished: %d/%d", total, target)
  end

  if kind == "business_value" then
    local target = tonumber(g.targetAmount)
    if not target or target <= 0 then
      target = 50000
    end
    local cash = 0
    if career_modules_bank then
      local account = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
      local accountId = account and (account.id or account.accountId)
      if accountId then
        cash = math.floor(math.max(0, tonumber(career_modules_bank.getAccountBalance(accountId)) or 0))
      end
    end
    local fleetValue = 0
    if career_modules_business_businessInventory and career_modules_business_businessInventory.getBusinessVehicles then
      local vehicles = career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}
      for _, vehicle in ipairs(vehicles) do
        fleetValue = fleetValue + rtState.rtInternal.getTeamVehicleBookValue(vehicle)
      end
    end
    local teamValue = cash + fleetValue
    if teamValue >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Value: $%d / $%d", teamValue, math.floor(target))
  end

  if kind == "ai_race_wins" then
    local target = tonumber(g.targetWins) or 10
    if target < 1 then
      target = 10
    end
    local total = 0
    for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if t and not t.fired then
        total = total + math.max(0, math.floor(tonumber(t.sanctionedRaceWins) or 0))
      end
    end
    if total >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Wins: %d/%d", total, target)
  end

  if kind == "cash_reserve" then
    local target = tonumber(g.targetAmount)
    if not target or target <= 0 then
      target = 100000
    end
    local cash = 0
    if career_modules_bank then
      local account = career_modules_bank.getBusinessAccount(rtState.businessType, businessId)
      local accountId = account and (account.id or account.accountId)
      if accountId then
        cash = math.floor(math.max(0, tonumber(career_modules_bank.getAccountBalance(accountId)) or 0))
      end
    end
    if cash >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("$%d / $%d", cash, math.floor(target))
  end

  if not hasBusinessVehicle(businessId) then
    return false, g.progressNoVehicle or g.progressLabel or "Purchase a team vehicle"
  end

  if kind == "vehicle_tier_up" then
    if fleetHasSuperBranchVehicle(businessId) then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, g.progressLabel or "Super class not owned"
  end

  if kind == "fleet_diversity" then
    local modMin = tonumber(g.fleetModifiedMin)
    local supMin = tonumber(g.fleetSuperMin)
    if supMin and supMin > 0 and (not modMin or modMin <= 0) then
      local supN = countFleetSanctionedBranch(businessId, "super")
      if supN >= supMin then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
      return false, string.format("Fleet: Super %d/%d", supN, supMin)
    end
    if modMin and supMin and modMin > 0 and supMin > 0 then
      local modN = countFleetSanctionedBranch(businessId, "modified")
      local supN = countFleetSanctionedBranch(businessId, "super")
      if modN >= modMin and supN >= supMin then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
      return false, string.format("Fleet: Modified %d/%d, Super %d/%d", modN, modMin, supN, supMin)
    end
    local ms = tostring(g.milestone or "")
    if ms == "grid_presence" then
      local vehCount = #(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {})
      local drvCount = 0
      for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
        if t and not t.fired then
          drvCount = drvCount + 1
        end
      end
      if vehCount >= 2 and drvCount >= 2 then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
      return false, g.progressLabel or "Requirements not met"
    end
    if ms == "scaled_operation" then
      local vehCount = #(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {})
      if vehCount >= 4 then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
      return false, string.format("Cars: %d/4", vehCount)
    end
    return false, g.progressLabel or "Requirements not met"
  end

  if kind == "reliability_streak" then
    local target = tonumber(g.targetRaces) or 25
    if target < 1 then
      target = 25
    end
    local total = 0
    for _, t in ipairs(rtState.loadRacingTeamDrivers(businessId)) do
      if t and not t.fired then
        total = total + math.max(0, math.floor(tonumber(t.sanctionedRacesFinished) or 0))
      end
    end
    if total >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Races finished: %d/%d", total, target)
  end

  if kind == "vehicle_and_leaderboard" then
    local rt, rl = g.raceType, g.raceLabel
    if not rt or not rl then
      return false, g.progressLabel or "Not configured"
    end
    local best = getBestTimeAcrossAllTeamJobs(businessId, rt, rl)
    if best and best > 0 then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, g.progressNoTime or g.progressLabel or "Complete a timed lap in your team car"
  end

  if kind == "all_leaderboards" then
    local function findBaselineSecForTrack(entries, rt, rl)
      if not entries then
        return nil
      end
      for _, e in ipairs(entries) do
        if e.raceType == rt and e.raceLabel == rl then
          local b = tonumber(e.baselineSec)
          if b and b > 0 then
            return b
          end
          return nil
        end
      end
      return nil
    end
    local function trackLeaderboardBeatsBaseline(current, baselineSec)
      if not current or current <= 0 then
        return false
      end
      if not baselineSec or baselineSec <= 0 then
        return true
      end
      return current + 1e-6 < baselineSec
    end
    local tracks = g.tracks
    if not tracks or #tracks == 0 then
      return false, g.progressLabel or "Not configured"
    end
    local baselineEntries = nil
    if type(g.baselineAfterGoalId) == "string" then
      baselineEntries = rtState.rtInternal.ensureAllLeaderboardsBaselineForGoal(businessId, g)
    end
    local parts = {}
    local allOk = true
    for _, tr in ipairs(tracks) do
      local rt, rl = tr.raceType, tr.raceLabel
      local shortName = tr.shortName or rl or rt or "?"
      if not rt or not rl then
        allOk = false
        table.insert(parts, shortName .. ": ?")
      else
        local current = getBestTimeAcrossAllTeamJobs(businessId, rt, rl)
        local base = baselineEntries and findBaselineSecForTrack(baselineEntries, rt, rl) or nil
        local trackOk = false
        if baselineEntries == nil then
          trackOk = current and current > 0
        else
          trackOk = trackLeaderboardBeatsBaseline(current, base)
        end
        if trackOk then
          table.insert(parts, shortName .. ": " .. M.formatRaceTime(current))
        else
          allOk = false
          if current and current > 0 then
            table.insert(parts, shortName .. ": " .. M.formatRaceTime(current))
          else
            table.insert(parts, shortName .. ": --")
          end
        end
      end
    end
    return allOk, table.concat(parts, " | ")
  end

  if kind == "tuning_milestone" then
    local id = tostring(normalizeBusinessId(businessId))
    local gid = tostring(g.id or "")
    if M.idCompleted(businessId, gid) then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    if M.tuningMilestonePreDoneForGoal(businessId, gid) then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    if gid == HOME_MECHANIC_GOAL_ID then
      local base = rtState.homeMechanicBaselinePwByBusiness[id]
      if base and base > 0 then
        return false, "Install upgrades or run the dyno to raise your car's power class"
      end
      return false, g.progressLabel or "Install parts or dyno a team car to start"
    end
    if gid == RT_T2_G4_TUNING_GOAL_ID then
      if fleetHasVehicleNearSanctionedBracketTop(businessId, "modified_club_low") then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
    elseif gid == RT_T2_G6_TUNING_GOAL_ID then
      if fleetHasVehicleInSanctionedBracket(businessId, "modified_club_mid") then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
    elseif gid == RT_T3_G3_TUNING_GOAL_ID then
      local peak = maxFleetDynoPeakHp(businessId)
      if peak >= TIER3_DYNO_MIN_HP then
        return true, g.progressDone or (g.targetLabel or "Complete")
      end
      if peak > 0 then
        return false, string.format("Best dyno: %d hp — need %d hp", math.floor(peak), TIER3_DYNO_MIN_HP)
      end
    end
    return false, g.progressLabel or "No upgrades detected"
  end

  if kind == "stamina_run" then
    local target = tonumber(g.targetLaps) or 5
    local streak = rtState.rtInternal.getStaminaStreak(businessId)
    local def = M.loadDefinition()
    local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
    local headId = getLeagueHeadGoalId(businessId, def, leagueId)
    if g.id and headId ~= g.id then
      return false, string.format("Short Track laps: %d/%d", streak, target)
    end
    if streak >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Short Track laps: %d/%d", streak, target)
  end

  if kind == "race_wins" then
    local target = tonumber(g.targetWins) or 3
    local wins = rtState.rtInternal.getSanctionedOfficialFirstPlaceWins(businessId)
    if wins >= target then
      return true, g.progressDone or (g.targetLabel or "Complete")
    end
    return false, string.format("Wins: %d/%d", wins, target)
  end

  if kind == "class_optimization" then
    -- The Stock/Modified PW brackets overlap. The branch resolver picks the
    -- highest-rank branch containing the PW, so a car at e.g. 0.2741 PW
    -- classifies as Modified for race entry. We check the resolved branch
    -- instead of a raw PW ceiling so this matches the entry path.
    local targetStr = "Tune a team car until it counts as Modified class or higher"
    local bestBranch = rtState.rtInternal.getSanctionedBranchFilterForBusiness(businessId) or "stock"
    local branchRank = { stock = 1, modified = 2, super = 3, open = 4 }
    local r = branchRank[tostring(bestBranch)] or 1
    if r >= 2 then
      return true, g.progressDone or (g.targetLabel or "Complete"), targetStr
    end
    return false, "Your fastest team car is still in Stock class — add power or reduce weight", targetStr
  end

  return false, g.progressLabel or "Not Started"
end

-- === Part/dyno notifications (called by businessComputer + businessPartCustomization)
function M.notifyBusinessVehiclePartsPurchased(businessId, parts)
  local bid = normalizeBusinessId(businessId)
  if not bid or type(parts) ~= "table" then
    return
  end
  rtState.rtInternal.getOfferState(bid)
  scheduleHomeMechanicPwRecheckAfterParts(bid)
end

-- BeamNG powertrain engine.maxPower is measured in Watts (e.g. 150,000 W = ~201 mechanical HP).
-- 1 Mechanical Horsepower = 745.699872 Watts.
local WATTS_PER_HP = 745.699872
local function ensureHorsepower(power)
  local p = tonumber(power)
  if not p or p <= 0 then return 0 end
  -- If power is provided in Watts (> 10 kW), convert to mechanical horsepower
  if p > 10000 then return p / WATTS_PER_HP end
  return p
end

-- Resolve the catalog/baseline horsepower for a fleet vehicle
local function getVehicleCatalogBaselineHp(targetVehicle, curHp)
  if curHp and curHp > 0 then return curHp end
  if not targetVehicle then return nil end

  local vc = targetVehicle.vehicleConfig
  local mk = vc and vc.model_key or targetVehicle.model_key
  local ck = vc and (vc.key or vc.config_key) or targetVehicle.config_key
  local getCat = rtState.rtInternal.getCatalogVehicleInfo or (career_modules_business_racingTeam and career_modules_business_racingTeam.getCatalogVehicleInfo)
  local vi = getCat and getCat(mk, ck)
  if not vi then return nil end
  return tonumber(vi.Power) or (vi.aggregates and vi.aggregates.Power and (tonumber(vi.aggregates.Power.min) or tonumber(vi.aggregates.Power.max)))
end

function M.notifyTeamVehicleDynoPeakHp(businessId, vehicleId, powerHp, weightKgOpt)
  local bid = normalizeBusinessId(businessId)
  if not bid or vehicleId == nil then
    return
  end
  local p = ensureHorsepower(powerHp)
  if p <= 0 then
    return
  end
  if career_modules_business_businessManager and career_modules_business_businessManager.getPurchasedBusinesses then
    local pb = career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType) or {}
    if not pb[bid] and not pb[tostring(bid)] then
      return
    end
  end
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    return
  end
  local vehicles = career_modules_business_businessInventory.getBusinessVehicles(bid) or {}
  local targetVehicle = nil
  for _, v in ipairs(vehicles) do
    if tostring(v.vehicleId) == tostring(vehicleId) then
      targetVehicle = v
      break
    end
  end
  if not targetVehicle then
    return
  end
  rtState.rtInternal.getOfferState(bid)
  local id = tostring(bid)
  rtState.classOptimizationPeakHpByBusiness[id] = rtState.classOptimizationPeakHpByBusiness[id] or {}
  local vidStr = tostring(vehicleId)
  local cur = rtState.classOptimizationPeakHpByBusiness[id][vidStr]
  local curHp, curW = nil, nil
  if type(cur) == "table" then
    curHp = tonumber(cur.hp)
    curW = tonumber(cur.weightKg)
  else
    curHp = tonumber(cur)
  end
  local wIn = tonumber(weightKgOpt)
  local newW = wIn
  if (not newW or newW <= 0) and curW and curW > 0 then
    newW = curW
  end
  local newEntry
  if newW and newW > 0 then
    newEntry = { hp = p, weightKg = newW }
  else
    newEntry = p
  end
  local hpChanged = (curHp == nil or math.abs(p - curHp) > 0.05)
  local wChanged = false
  if newW and newW > 0 then
    wChanged = (curW == nil or math.abs(newW - curW) > 0.5)
  end

  local dynoLevel = rtState.rtInternal.getSkillTreeNodeLevel and rtState.rtInternal.getSkillTreeNodeLevel(bid, "qol", "dyno") or 0
  if dynoLevel > 0 then
    -- Workshop Dyno is unlocked: certify official vehicle power and clear any dyno-required flag
    local wasRequired = (rtState.dynoRequiredByBusiness and rtState.dynoRequiredByBusiness[id] and rtState.dynoRequiredByBusiness[id][vidStr] == true)
    if rtState.dynoRequiredByBusiness and rtState.dynoRequiredByBusiness[id] then rtState.dynoRequiredByBusiness[id][vidStr] = nil end
    if hpChanged or wChanged or wasRequired then
      rtState.classOptimizationPeakHpByBusiness[id][vidStr] = newEntry
      local _, savePath = career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.rtInternal.saveRacingTeamPersistedState(bid, savePath)
      end
      racingTeamRaceOffers.bumpRefresh(bid)
      if rtState.rtInternal.advanceRacingTeamGoalsIfReady then
        rtState.rtInternal.advanceRacingTeamGoalsIfReady(bid)
      end
      maybeCompleteHomeMechanicFromFleetPw(bid)
    end
  else
    -- Without Workshop Dyno: check +5% watchdog rule against baseline catalog power.
    -- Vehicles modified past +5% tolerance are flagged until certified on the paddock dyno.
    local baseHp = getVehicleCatalogBaselineHp(targetVehicle, curHp)
    local isRequired = (baseHp and baseHp > 0 and ((p - baseHp) / baseHp > 0.05)) or false

    rtState.dynoRequiredByBusiness[id] = rtState.dynoRequiredByBusiness[id] or {}
    local wasRequired = rtState.dynoRequiredByBusiness[id][vidStr] == true

    if isRequired ~= wasRequired then
      rtState.dynoRequiredByBusiness[id][vidStr] = isRequired and true or nil
      local _, savePath = career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.rtInternal.saveRacingTeamPersistedState(bid, savePath)
      end
      racingTeamRaceOffers.bumpRefresh(bid)
    end
  end
end

-- === Goal completion
function M.markGoalCompleted(businessId, goalId)
  local id = tostring(normalizeBusinessId(businessId))
  rtState.goalCompletionByBusiness[id] = rtState.goalCompletionByBusiness[id] or {}
  if rtState.goalCompletionByBusiness[id][goalId] == true then
    return
  end
  rtState.goalCompletionByBusiness[id][goalId] = true
  local dl = rtState.rtInternal.devLog
  if dl and dl.append then
    dl.append(businessId, "info", "Goal completed: " .. tostring(goalId), "goals")
  end
  snapshotCompletedGoalLeaderboardTimesAtCompletion(businessId, goalId)
  rtState.rtInternal.recordBaselinesAfterCompletedPrerequisite(businessId, goalId)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if rtState.rtInternal.syncRacingTeamDriverUnlock then
    rtState.rtInternal.syncRacingTeamDriverUnlock(businessId)
  end
  if goalId == rtState.K.GOAL_UNLOCK_SANCTIONED_RACE_OFFERS then
    local board = rtState.rtInternal.getRaceOfferBoard(businessId)
    board.nextRefreshAt = 0
    rtState.raceUnlockSplashPendingByBusiness[id] = true
    rtState.raceUnlockSplashShownByBusiness[id] = false
  end
  if rtState.rtInternal.refreshLeague2InviteOffer then
    rtState.rtInternal.refreshLeague2InviteOffer(businessId)
  end
  if rtState.rtInternal.allGoalsCompleteForLeague
      and rtState.rtInternal.allGoalsCompleteForLeague(businessId, "league4")
      and rtState.careerFinaleSplashShownByBusiness[id] ~= true then
    rtState.careerFinaleSplashPendingByBusiness[id] = true
    if rtState.rtInternal.scheduleCareerFinaleSplash then
      rtState.careerFinaleSplashPendingByBusiness[id] = false
      rtState.rtInternal.scheduleCareerFinaleSplash(businessId)
    end
  end
  if rtState.rtInternal.notifyBusinessComputerRacingTeamGoalProgress then
    rtState.rtInternal.notifyBusinessComputerRacingTeamGoalProgress(businessId, goalId)
  end
  resetStaminaStreakIfStaminaGoalIsHead(businessId)
end

-- === Short Track stamina lap handler
function M.notifyShortTrackStaminaLap(payload)
  if type(payload) ~= "table" then
    log("I", "racingTeam", "stamina_lap skip payload_not_table")
    return
  end
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId then
    log("I", "racingTeam", "stamina_lap skip no_businessInventory.getBusinessVehicleFromSpawnedId")
    return
  end
  local pv = payload.playerVehicleId
  log("I", "racingTeam", string.format(
    "stamina_lap enter raceLabel=%s isAltRoute=%s invalidLap=%s dmgFactor=%s dmgPct=%s pv=%s",
    tostring(payload.raceLabel),
    tostring(payload.isAltRoute),
    tostring(payload.invalidLap),
    tostring(payload.damageFactor),
    tostring(payload.damagePercentage),
    tostring(pv)
  ))
  if not pv then
    log("I", "racingTeam", "stamina_lap skip no_playerVehicleId")
    return
  end
  local businessId, fleetVehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(pv)
  if not businessId or fleetVehicleId == nil then
    log("I", "racingTeam", string.format(
      "stamina_lap skip not_team_spawn pv=%s businessId=%s fleetVehicleId=%s",
      tostring(pv), tostring(businessId), tostring(fleetVehicleId)
    ))
    return
  end
  if career_modules_business_businessManager and career_modules_business_businessManager.getPurchasedBusinesses then
    local pb = career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType) or {}
    local nb = normalizeBusinessId(businessId)
    if not pb[nb] and not pb[tostring(nb)] then
      log("I", "racingTeam", string.format(
        "stamina_lap skip business_not_purchased businessId=%s normalized=%s",
        tostring(businessId), tostring(nb)
      ))
      return
    end
  end
  rtState.rtInternal.getOfferState(businessId)
  local raceLabel = tostring(payload.raceLabel or "")
  if not string.find(raceLabel, "Short Track", 1, true) then
    log("I", "racingTeam", string.format(
      "stamina_lap skip raceLabel_no_Short_Track_substring got=%s businessId=%s",
      raceLabel, tostring(businessId)
    ))
    return
  end
  local def = M.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local staminaGoalId, targetLaps = nil, 5
  if def and type(def.goals) == "table" then
    for _, gg in ipairs(def.goals) do
      if gg and gg.kind == "stamina_run" and M.resolvedLeague(gg) == leagueId then
        staminaGoalId = gg.id
        targetLaps = tonumber(gg.targetLaps) or 5
        break
      end
    end
  end
  if not staminaGoalId or M.idCompleted(businessId, staminaGoalId) then
    log("I", "racingTeam", string.format(
      "stamina_lap skip no_stamina_goal_or_done businessId=%s league=%s staminaGoalId=%s goalDone=%s",
      tostring(businessId),
      tostring(leagueId),
      tostring(staminaGoalId),
      tostring(staminaGoalId and M.idCompleted(businessId, staminaGoalId))
    ))
    return
  end
  local headId = getLeagueHeadGoalId(businessId, def, leagueId)
  if headId ~= staminaGoalId then
    log("I", "racingTeam", string.format(
      "stamina_lap skip not_active_goal businessId=%s headId=%s staminaGoalId=%s",
      tostring(businessId), tostring(headId), tostring(staminaGoalId)
    ))
    return
  end
  local prev = rtState.rtInternal.getStaminaStreak(businessId)
  if prev >= targetLaps then
    log("W", "racingTeam", string.format(
      "stamina_lap streak already at/above target before lap; attempting goal complete businessId=%s prev=%s targetLaps=%s goalId=%s",
      tostring(businessId), tostring(prev), tostring(targetLaps), tostring(staminaGoalId)
    ))
    if staminaGoalId and not M.idCompleted(businessId, staminaGoalId) then
      M.markGoalCompleted(businessId, staminaGoalId)
    end
    if not M.idCompleted(businessId, staminaGoalId) then
      rtState.rtInternal.setStaminaStreak(businessId, 0)
    end
    prev = rtState.rtInternal.getStaminaStreak(businessId)
  end
  local invalid = payload.invalidLap == true
  local dmgFactor = tonumber(payload.damageFactor) or 0
  local dmgPct = tonumber(payload.damagePercentage) or 0
  local critical = dmgFactor > 0 and dmgPct >= 0.22
  if invalid or critical then
    rtState.rtInternal.setStaminaStreak(businessId, 0)
    local _, savePath = career_saveSystem.getCurrentProfile()
    if savePath then
      rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
    end
    log("I", "racingTeam", string.format(
      "stamina lap reset business=%s invalid=%s criticalDmg=%s",
      tostring(businessId), tostring(invalid), tostring(critical)
    ))
    return
  end
  local nextStreak = prev + 1
  rtState.rtInternal.setStaminaStreak(businessId, nextStreak)
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
  end
  if nextStreak >= targetLaps then
    M.markGoalCompleted(businessId, staminaGoalId)
  end
  log("I", "racingTeam", string.format(
    "stamina lap business=%s streak=%d/%d label=%s",
    tostring(businessId), nextStreak, targetLaps, raceLabel
  ))
end

-- === Official sanctioned podium handler
function M.notifyOfficialSanctionedPodium(place, offer)
  local p = tonumber(place)
  if not p or p < 1 or p > 3 then
    return
  end
  if not career_modules_business_businessManager or not career_modules_business_businessManager.getPurchasedBusinesses then
    return
  end
  if not gameplay_events_freContracts_state or not gameplay_events_freContracts_state.isCareerActive
      or not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  local def = M.loadDefinition()
  local allGoals = def and def.goals
  local purchased = career_modules_business_businessManager.getPurchasedBusinesses(rtState.businessType) or {}
  local businessList = {}
  if type(offer) == "table" and offer.racingTeamBusinessOffer == true and offer.businessId ~= nil then
    local bid = normalizeBusinessId(offer.businessId)
    if isPurchasedRacingTeamBusiness(purchased, bid) then
      businessList[1] = bid
    else
      return
    end
  else
    for businessId, _ in pairs(purchased) do
      table.insert(businessList, businessId)
    end
  end
  for _, businessId in ipairs(businessList) do
    rtState.rtInternal.getOfferState(businessId)
    local makeYourMarkDoneBefore = M.idCompleted(businessId, rtState.K.GOAL_MAKE_YOUR_MARK)
    local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
    local targetId = nil
    if type(allGoals) == "table" then
      for _, g in ipairs(allGoals) do
        if g.id and (g.kind or "") == "sanctioned_podium" and M.resolvedLeague(g) == leagueId then
          targetId = g.id
          break
        end
      end
    end
    if not targetId then
      targetId = rtState.K.GOAL_MAKE_YOUR_MARK
    end
    local offerIsTeamBoard = type(offer) == "table" and offer.racingTeamBusinessOffer == true and offer.businessId ~= nil
    local goalKindForTarget = nil
    if type(allGoals) == "table" then
      for _, gg in ipairs(allGoals) do
        if gg and gg.id == targetId then
          goalKindForTarget = gg.kind
          break
        end
      end
    end
    local podiumTeamBoardOnly = (goalKindForTarget == "sanctioned_podium")
        or (goalKindForTarget == nil and targetId == rtState.K.GOAL_MAKE_YOUR_MARK)
    local skipMark = podiumTeamBoardOnly and not offerIsTeamBoard
    if not skipMark and not M.idCompleted(businessId, targetId) then
      M.markGoalCompleted(businessId, targetId)
    end
    local matches = racingTeamOfferMatchesBusiness(businessId, offer)
    local l1pr = type(offer) == "table" and offer.league1PlayerRace == true
    log("I", "racingTeam", string.format(
      "notifyOfficialSanctionedPodium bid=%s p=%s makeYourMarkDoneBefore=%s matches=%s league1PlayerRace=%s teamOffer=%s offerBid=%s",
      tostring(businessId),
      tostring(p),
      tostring(makeYourMarkDoneBefore),
      tostring(matches),
      tostring(l1pr),
      tostring(type(offer) == "table" and offer.racingTeamBusinessOffer == true),
      tostring(type(offer) == "table" and offer.businessId)
    ))
    if p == 1 and makeYourMarkDoneBefore and matches and l1pr then
      local idStr = tostring(normalizeBusinessId(businessId))
      local before = rtState.sanctionedOfficialFirstPlaceWinsByBusiness[idStr] or 0
      rtState.sanctionedOfficialFirstPlaceWinsByBusiness[idStr] = before + 1
      log("I", "racingTeam", string.format(
        "notifyOfficialSanctionedPodium INCREMENT bid=%s %d -> %d",
        idStr, before, before + 1
      ))
      local _, savePath = career_saveSystem.getCurrentProfile()
      if savePath then
        rtState.rtInternal.saveRacingTeamPersistedState(businessId, savePath)
      end
    end
  end
end

-- === League advancement helpers (cross-module via rtInternal)
function rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
  rtState.rtInternal.getOfferState(businessId)
  local def = M.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = M.getSortedForLeague(def, leagueId)
  local safety = 0
  local advancedAnyGoal = false
  while safety < 32 do
    safety = safety + 1
    local current = nil
    for _, g in ipairs(leagueGoals) do
      if g.id and not M.idCompleted(businessId, g.id) then
        current = g
        break
      end
    end
    if not current then
      break
    end
    local done = select(1, M.evaluateGoalProgress(businessId, current))
    if done then
      M.markGoalCompleted(businessId, current.id)
      advancedAnyGoal = true
    else
      break
    end
  end
  if advancedAnyGoal and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

function rtState.rtInternal.allGoalsCompleteForLeague(businessId, leagueId)
  local def = M.loadDefinition()
  if not def or type(def.goals) ~= "table" then
    return false
  end
  local sawAny = false
  for _, g in ipairs(def.goals) do
    if g and g.id and M.resolvedLeague(g) == leagueId then
      sawAny = true
      if not M.idCompleted(businessId, g.id) then
        return false
      end
    end
  end
  return sawAny
end

function rtState.rtInternal.allTierOneGoalsComplete(businessId)
  return rtState.rtInternal.allGoalsCompleteForLeague(businessId, "league1")
end

-- === Cross-module exposure (rtInternal mirrors)
rtState.rtInternal.evaluateGoalProgress = M.evaluateGoalProgress
rtState.rtInternal.markGoalCompleted = M.markGoalCompleted

local function goalRowToUi(g, progressLabel, status, leagueLabel, targetLabelOverride)
  local lg = leagueLabel or M.resolvedLeague(g)
  return {
    id = g.id,
    title = g.title or "",
    description = g.description or "",
    targetLabel = targetLabelOverride or g.targetLabel or "",
    progressLabel = progressLabel or g.progressLabel or "Not Started",
    tier = g.tier,
    order = g.order,
    league = lg,
    status = status or g.status or "active"
  }
end

function M.getActiveList(businessId)
  rtState.rtInternal.getOfferState(businessId)
  local def = M.loadDefinition()
  local leagueId = rtState.rtInternal.getCurrentLeague(businessId)
  local leagueGoals = M.getSortedForLeague(def, leagueId)
  local rows = {}
  local safety = 0
  local advancedAnyGoal = false
  while safety < 32 do
    safety = safety + 1
    local current = nil
    for _, g in ipairs(leagueGoals) do
      if g.id and not M.idCompleted(businessId, g.id) then
        current = g
        break
      end
    end
    if not current then
      break
    end
    local done, progressLabel, targetLabelOverride = M.evaluateGoalProgress(businessId, current)
    if done then
      M.markGoalCompleted(businessId, current.id)
      advancedAnyGoal = true
    else
      table.insert(rows, goalRowToUi(current, progressLabel, "active", leagueId, targetLabelOverride))
      break
    end
  end
  if advancedAnyGoal and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return rows, leagueId, leagueGoals
end

local function buildCompletedBestTimesSummary(businessId, g)
  local function formatMinSec(seconds)
    if not seconds or seconds <= 0 then
      return "--"
    end
    local s = tonumber(seconds) or 0
    local mi = math.floor(s / 60)
    local secPart = s - mi * 60
    return string.format("%d:%05.2f", mi, secPart)
  end

  if not g or type(g) ~= "table" or not g.id then
    return nil
  end
  local id = tostring(normalizeBusinessId(businessId))
  local snap = (rtState.completedGoalLeaderboardTimesByBusiness[id] or {})[g.id]
  local kind = g.kind or ""
  if kind == "vehicle_and_leaderboard" then
    local rt, rl = g.raceType, g.raceLabel
    if not rt or not rl then
      return nil
    end
    local best = snap and snap.kind == "single" and tonumber(snap.bestSec) or nil
    if not best or best <= 0 then
      return "Best time: --"
    end
    return "Best time: " .. formatMinSec(best)
  end
  if kind == "all_leaderboards" then
    local tracks = g.tracks
    if type(tracks) ~= "table" or #tracks == 0 then
      return nil
    end
    local function historicalSecForTrack(rt, rl)
      if not snap or snap.kind ~= "tracks" or type(snap.tracks) ~= "table" then
        return nil
      end
      for _, row in ipairs(snap.tracks) do
        if row.raceType == rt and row.raceLabel == rl then
          return tonumber(row.bestSec)
        end
      end
      return nil
    end
    local parts = {}
    for _, tr in ipairs(tracks) do
      local rt, rl = tr.raceType, tr.raceLabel
      local shortName = tr.shortName or rl or rt or "?"
      if rt and rl then
        local t = historicalSecForTrack(rt, rl)
        table.insert(parts, shortName .. ": " .. ((t and t > 0) and formatMinSec(t) or "--"))
      else
        table.insert(parts, shortName .. ": --")
      end
    end
    if #parts == 0 then
      return nil
    end
    return "Best times: " .. table.concat(parts, " | ")
  end
  return nil
end

function M.getCompletedList(businessId)
  rtState.rtInternal.getOfferState(businessId)
  local def = M.loadDefinition()
  local goals = def and def.goals
  local byId = {}
  if type(goals) == "table" then
    for _, g in ipairs(goals) do
      if g.id then
        byId[g.id] = g
      end
    end
  end
  local id = tostring(normalizeBusinessId(businessId))
  local out = {}
  for gid, done in pairs(rtState.goalCompletionByBusiness[id] or {}) do
    if done and byId[gid] then
      local g = byId[gid]
      local row = goalRowToUi(g, g.progressDone or g.progressLabel or "Complete", "complete")
      local timesSummary = buildCompletedBestTimesSummary(businessId, g)
      if timesSummary then
        row.completedBestTimesSummary = timesSummary
      end
      table.insert(out, row)
    end
  end
  table.sort(out, function(a, b)
    local la = leagueRankSortKey(a.league)
    local lb = leagueRankSortKey(b.league)
    if la ~= lb then
      return la < lb
    end
    return (tonumber(a.order) or 0) < (tonumber(b.order) or 0)
  end)
  return out
end

function M.buildDisplays(businessId)
  local def = M.loadDefinition()
  local goals = def and def.goals
  if not goals or #goals == 0 then
    local row = goalRowToUi({
      id = "rt_t1_g1",
      title = "First Outing",
      description = "Purchase a vehicle and complete 1 lap on the Short Track",
      targetLabel = "Complete one lap",
      progressLabel = "Not Started",
      tier = 1,
      order = 1,
      status = "active"
    }, "Not Started", "active", "league1")
    return row, {}, "league1"
  end

  local activeGoals, leagueId, leagueGoals = M.getActiveList(businessId)
  if #activeGoals > 0 then
    return activeGoals[1], activeGoals, leagueId
  end
  if leagueGoals and #leagueGoals > 0 then
    local allDone = true
    for _, g in ipairs(leagueGoals) do
      if g.id and not M.idCompleted(businessId, g.id) then
        allDone = false
        break
      end
    end
    if allDone then
      local last = leagueGoals[#leagueGoals]
      local row = goalRowToUi(last, leagueStuckCapProgressLabel(leagueId), "completed", leagueId)
      return row, activeGoals, leagueId
    end
  end
  local fallback = (leagueGoals and leagueGoals[1]) or goals[1]
  if not fallback then
    local row = goalRowToUi({
      id = "none",
      title = "Goals",
      description = "No goals configured",
      order = 1,
    }, "Not configured", "active", leagueId or "league1")
    return row, activeGoals, leagueId or "league1"
  end
  local row = goalRowToUi(fallback, fallback.progressLabel or "Not Started", "active", leagueId or M.resolvedLeague(fallback))
  return row, activeGoals, leagueId or M.resolvedLeague(fallback)
end

return M
