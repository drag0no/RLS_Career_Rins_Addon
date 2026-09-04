local M = {}

local businessType = "racingTeam"
local PAYMENT_INTERVAL = 1800

local SHOP_OVERHEAD_COST_SCALE = 0.15

local function scaleShopOverhead(amount)
  return math.max(0, math.floor((tonumber(amount) or 0) * SHOP_OVERHEAD_COST_SCALE + 0.5))
end

local operatingCostTimers = {}
local simStepAccumulator = 0
local SIM_STEP_INTERVAL = 1

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function getTimerFilePath(businessId)
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return nil
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if not savePath or not businessId then
    return nil
  end
  return savePath .. "/career/rls_career/businesses/" .. tostring(businessId) .. "/racingTeamShopOperatingCost.json"
end

local function loadTimerFromDisk(businessId)
  businessId = normalizeBusinessId(businessId)
  local path = getTimerFilePath(businessId)
  if not path or not FS or not FS:fileExists(path) then
    return { elapsed = 0, lastChargeTime = nil }
  end
  local data = jsonReadFile(path) or {}
  return {
    elapsed = tonumber(data.elapsed) or 0,
    lastChargeTime = data.lastChargeTime,
  }
end

local function saveTimerToDisk(businessId, currentSavePath)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not currentSavePath then
    return
  end
  local state = operatingCostTimers[businessId]
  if not state then
    return
  end
  local path = currentSavePath .. "/career/rls_career/businesses/" .. tostring(businessId) .. "/racingTeamShopOperatingCost.json"
  local dirPath = string.match(path, "^(.*)/[^/]+$")
  if dirPath and FS and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  jsonWriteFile(path, { elapsed = state.elapsed, lastChargeTime = state.lastChargeTime }, true)
end

local function loadOperatingCostTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { elapsed = 0, lastChargeTime = nil }
  end
  if operatingCostTimers[businessId] == nil then
    operatingCostTimers[businessId] = loadTimerFromDisk(businessId)
  end
  return operatingCostTimers[businessId] or { elapsed = 0, lastChargeTime = nil }
end

function M.saveOperatingCostTimers(currentSavePath)
  if not currentSavePath then
    return
  end
  for bid, _ in pairs(operatingCostTimers) do
    saveTimerToDisk(bid, currentSavePath)
  end
end

function M.clearOperatingCostTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then return false end
  operatingCostTimers[businessId] = { elapsed = 0, lastChargeTime = nil }
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    saveTimerToDisk(businessId, savePath)
  end
  return true
end

function M.onCareerActivated()
  operatingCostTimers = {}
end

local function countActiveRacingDrivers(businessId)
  local mgr = career_modules_business_businessManager
  if not mgr or not mgr.getBusinessObject then
    return 0
  end
  local obj = mgr.getBusinessObject("racingTeam")
  if not obj or not obj.getTechsForBusiness then
    return 0
  end
  local techs = obj.getTechsForBusiness(businessId) or {}
  local n = 0
  for _, t in ipairs(techs) do
    if not t.fired then
      n = n + 1
    end
  end
  return n
end

local function getShopOperatingCosts(businessId)
  if not businessId then
    local base = scaleShopOverhead(5000)
    return {
      baseLift = base,
      additionalLifts = 0,
      techs = 0,
      manager = 0,
      generalManager = 0,
      total = base,
    }
  end

  local baseLift = scaleShopOverhead(5000)
  local additionalLifts = 0
  local techsCost = 0
  local managerCost = 0
  local generalManagerCost = 0

  if career_modules_business_businessSkillTree then
    local treeId = "team-operations"
    local kitLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "kit-storage") or 0
    additionalLifts = math.min(3, math.max(0, math.floor(kitLevel)))

    local managerLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, treeId, "manager") or 0
    if managerLevel > 0 then
      managerCost = scaleShopOverhead(5000)
    end
    local dynoLevel = career_modules_business_businessSkillTree.getNodeProgress(businessId, "qol", "dyno") or 0
    if dynoLevel > 0 then
      generalManagerCost = scaleShopOverhead(25000)
    end
  end

  local techCount = countActiveRacingDrivers(businessId)
  techsCost = techCount * scaleShopOverhead(2500)

  local additionalLiftsCost = additionalLifts * scaleShopOverhead(5000)
  local total = baseLift + additionalLiftsCost + techsCost + managerCost + generalManagerCost

  return {
    baseLift = baseLift,
    additionalLifts = additionalLifts,
    additionalLiftsCost = additionalLiftsCost,
    techs = techCount,
    techsCost = techsCost,
    manager = managerCost > 0 and 1 or 0,
    managerCost = managerCost,
    generalManager = generalManagerCost > 0 and 1 or 0,
    generalManagerCost = generalManagerCost,
    total = total,
    maxCost = scaleShopOverhead(55000),
  }
end

local function debitBusinessAccount(businessId, amount, reason, description)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.removeFunds then
    return false
  end
  local account = career_modules_bank.getBusinessAccount(businessType, businessId)
  if not account then
    return false
  end
  local accountId = account.id or account.accountId
  if not accountId then
    return false
  end
  return career_modules_bank.removeFunds(accountId, amount, reason or "Racing team expense", "", description or "", true)
end

local function processOperatingCosts(businessId, dtSim)
  if not businessId or dtSim <= 0 then
    return false
  end
  local operatingCosts = getShopOperatingCosts(businessId)
  if operatingCosts.total <= 0 then
    return false
  end

  local timerState = loadOperatingCostTimer(businessId)
  timerState.elapsed = timerState.elapsed + dtSim

  local charged = false
  if timerState.elapsed >= PAYMENT_INTERVAL then
    local currentTime = os.time()
    local success = debitBusinessAccount(businessId, operatingCosts.total, "Operating Costs",
      string.format(
        "Shop overhead: Base $%d, Bays $%d, Team $%d, Manager $%d, Ops $%d",
        operatingCosts.baseLift,
        operatingCosts.additionalLiftsCost,
        operatingCosts.techsCost,
        operatingCosts.managerCost,
        operatingCosts.generalManagerCost
      ))

    if success then
      timerState.elapsed = math.max(0, timerState.elapsed - PAYMENT_INTERVAL)
      timerState.lastChargeTime = currentTime
      charged = true
    else
      timerState.elapsed = 0
    end
  end

  operatingCostTimers[businessId] = timerState
  return charged
end

function M.onCareerSimStep(dtSim)
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return
  end
  if not dtSim or dtSim <= 0 then
    return
  end
  simStepAccumulator = simStepAccumulator + dtSim
  if simStepAccumulator < SIM_STEP_INTERVAL then
    return
  end
  local elapsed = simStepAccumulator
  simStepAccumulator = 0
  local mgr = career_modules_business_businessManager
  if not mgr or not mgr.getPurchasedBusinesses then
    return
  end
  local purchased = mgr.getPurchasedBusinesses("racingTeam")
  if not purchased then
    return
  end
  for bid, _ in pairs(purchased) do
    processOperatingCosts(bid, elapsed)
  end
end

local function leagueTierIndex(leagueIdStr)
  local m = string.match(tostring(leagueIdStr or ""), "^league(%d+)$")
  if m then
    return math.max(1, tonumber(m) or 1)
  end
  return 1
end

function M.computeRaceEntranceFee(offer, leagueIdStr)
  local br = "stock"
  if type(offer) == "table" and offer.hpBracketBranch then
    br = string.lower(tostring(offer.hpBracketBranch))
  end
  local base = 350
  if br == "modified" then
    base = 700
  elseif br == "super" then
    base = 1200
  elseif br == "open" then
    base = 700
  end
  local tier = leagueTierIndex(leagueIdStr)
  local mult = 1 + 0.2 * math.max(0, tier - 1)
  return math.floor(base * mult + 0.5)
end

function M.tryDebitRaceEntranceFee(businessId, offer, leagueIdStr)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  local fee = M.computeRaceEntranceFee(offer, leagueIdStr)
  if fee <= 0 then
    return true
  end
  local label = (type(offer) == "table" and (offer.raceLabel or offer.raceName)) or "Race"
  local cls = (type(offer) == "table" and offer.hpBracketBranch) and tostring(offer.hpBracketBranch) or "class"
  return debitBusinessAccount(
    businessId,
    fee,
    "Race entry fee",
    string.format("Entry — %s (%s)", label, cls)
  )
end

function M.refundRaceEntranceFee(businessId, offer, leagueIdStr)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local fee = M.computeRaceEntranceFee(offer, leagueIdStr)
  if fee <= 0 then
    return
  end
  if not career_modules_bank or not career_modules_bank.getBusinessAccount or not career_modules_bank.rewardToAccount then
    return
  end
  local account = career_modules_bank.getBusinessAccount(businessType, businessId)
  local accountId = account and (account.id or account.accountId)
  if not accountId then
    return
  end
  career_modules_bank.rewardToAccount({
    money = { amount = fee, canBeNegative = false },
  }, accountId, "Race entry fee (refund)", "Race start failed — entry fee returned")
end

local function driverCutBlendTFromXp(xp)
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

local function driverCutPercentFromRacingXp(xp)
  return 35 + 25 * driverCutBlendTFromXp(xp)
end

function M.applyDriverCutAfterPayout(businessId, grossAmount, opts)
  businessId = normalizeBusinessId(businessId)
  opts = opts or {}
  grossAmount = math.floor(tonumber(grossAmount) or 0)
  if not businessId or grossAmount <= 0 then
    return
  end
  local pct = driverCutPercentFromRacingXp(tonumber(opts.racingSkillXp) or 0)
  local cut = math.floor(grossAmount * pct / 100 + 0.5)
  if cut <= 0 then
    return
  end
  local dname = type(opts.driverName) == "string" and opts.driverName ~= "" and opts.driverName or "Driver"
  debitBusinessAccount(
    businessId,
    cut,
    "Driver cut",
    string.format("Driver share (%d%%) — %s", pct, dname)
  )
end

local function getRacingTeamFinancesData(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end

  local account = nil
  local accountBalance = 0
  local accountId = nil
  local transactions = {}
  local businessLoans = {}

  if career_modules_bank then
    account = career_modules_bank.getBusinessAccount(businessType, businessId)
    if account then
      accountId = account.id or account.accountId
      if accountId then
        accountBalance = career_modules_bank.getAccountBalance(accountId) or 0
        transactions = career_modules_bank.getAccountTransactions(accountId, 100) or {}
      end
    end
  end

  if career_modules_loans and accountId then
    local allLoans = career_modules_loans.getActiveLoans() or {}
    for _, loan in ipairs(allLoans) do
      if loan.businessAccountId == accountId then
        table.insert(businessLoans, loan)
      end
    end
  end

  local shop = getShopOperatingCosts(businessId)
  local operatingCosts = {
    total = shop.total,
    baseLift = shop.baseLift,
    additionalLifts = shop.additionalLifts,
    additionalLiftsCost = shop.additionalLiftsCost,
    techs = shop.techs,
    techsCost = shop.techsCost,
    manager = shop.manager,
    managerCost = shop.managerCost,
    generalManager = shop.generalManager,
    generalManagerCost = shop.generalManagerCost,
    maxCost = shop.maxCost,
    driverCutPercentMin = 35,
    driverCutPercentMax = 60,
    driverCutNote = "35%–60% of gross payout by driver skill (debited on deposit; see ledger).",
    raceEntryNote = "Due when you schedule a race (class & league; see ledger).",
  }

  local operatingCostTimer = nil
  if shop.total > 0 then
    local timerState = loadOperatingCostTimer(businessId)
    local remainingTime = PAYMENT_INTERVAL - (timerState.elapsed % PAYMENT_INTERVAL)
    operatingCostTimer = {
      elapsed = timerState.elapsed,
      lastChargeTime = timerState.lastChargeTime,
      paymentInterval = PAYMENT_INTERVAL,
      remainingTime = remainingTime,
    }
  end

  return {
    operatingCosts = operatingCosts,
    account = {
      id = accountId,
      balance = accountBalance,
      name = account and account.name or nil,
    },
    transactions = transactions,
    loans = businessLoans,
    operatingCostTimer = operatingCostTimer,
  }
end

function M.requestFinancesData(businessId)
  if not businessId then
    if guihooks then
      guihooks.trigger("businessComputer:onFinancesData", {
        success = false,
        error = "Missing businessId",
      })
    end
    return
  end

  local financesData = getRacingTeamFinancesData(businessId)
  if not financesData then
    if guihooks then
      guihooks.trigger("businessComputer:onFinancesData", {
        success = false,
        error = "Failed to get finances data",
        businessId = businessId,
      })
    end
    return
  end

  local data = {
    success = true,
    businessId = businessId,
    finances = financesData,
    simulationTime = os.time(),
  }

  if guihooks then
    guihooks.trigger("businessComputer:onFinancesData", data)
  end
end

function M.tryDebitVehiclePaintCost(businessId, amount, description)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  return debitBusinessAccount(
    businessId,
    amount,
    "Vehicle painting",
    description or "Repainted a fleet vehicle"
  )
end

function M.tryDebitVehicleFuelCost(businessId, amount, description)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  return debitBusinessAccount(
    businessId,
    amount,
    "Fuel",
    description or "Refueled a fleet vehicle"
  )
end

M.getRacingTeamFinancesData = getRacingTeamFinancesData
M.getShopOperatingCostsForDebug = getShopOperatingCosts

return M
