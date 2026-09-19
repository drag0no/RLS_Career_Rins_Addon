local M = {}

local freConfig = require("gameplay/fre/config")

local CONFIG_DIR = "competitiveRace"
local CONFIG_RACE_FILENAME = "aiRacingConfig.json"
local DISCIPLINE_ROAD = "roadracing"

local DEFAULT_PODIUM_MULT = { first = 8, second = 4.5, third = 2.5 }
local DEFAULT_PODIUM_VARIANCE = { min = 0.84, max = 1.16 }
local PLACE_JITTER = { min = 0.92, max = 1.08 }

-- Loopable sanctioned offers: max laps ≈ how many target-time laps fit in 10 minutes; roll min..max; scale payouts vs design lapCount in race_data.
local SANCTIONED_MAX_WINDOW_SEC = 600
local SANCTIONED_LAP_ROLL_CAP = 60
local SANCTIONED_MIN_LAP_COUNT = 2
local SANCTIONED_PODIUM_XP_OF_MONEY = 0.1

local function moneyToSanctionedXp(m)
  return math.max(0, math.floor((tonumber(m) or 0) * SANCTIONED_PODIUM_XP_OF_MONEY + 1e-9))
end

-- Baseline money (race reward at target time) is multiplied by branch before podium place multipliers.
local DEFAULT_CLASS_PAYOUT_MULT = {
  stock = 1,
  modified = 1.35,
  super = 1.85,
  open = 2.35,
}

-- Sub-brackets: power-to-weight in hp/kg (engine hp ÷ curb weight kg). Player-facing labels: Branch · Low/Mid/High.
local OPEN_SANCTIONED_PW_MIN = 0.4741
local OPEN_SANCTIONED_PW_MAX = 99.0
local OPEN_SANCTIONED_BRACKET_LABEL = "Open"
local DEFAULT_SANCTIONED_PW_BRACKETS = {
  { branch = "stock", id = "stock_street_entry", label = "Stock · Low", classPwMin = 0.0882, classPwMax = 0.1940, pickWeight = 1 },
  { branch = "stock", id = "stock_street_mid", label = "Stock · Mid", classPwMin = 0.1653, classPwMax = 0.2425, pickWeight = 1 },
  { branch = "stock", id = "stock_street_upper", label = "Stock · High", classPwMin = 0.2205, classPwMax = 0.2822, pickWeight = 1 },
  { branch = "modified", id = "modified_club_low", label = "Modified · Low", classPwMin = 0.2425, classPwMax = 0.3042, pickWeight = 1 },
  { branch = "modified", id = "modified_club_mid", label = "Modified · Mid", classPwMin = 0.2756, classPwMax = 0.3417, pickWeight = 1 },
  { branch = "modified", id = "modified_club_high", label = "Modified · High", classPwMin = 0.3197, classPwMax = 0.3792, pickWeight = 1 },
  { branch = "super", id = "super_track_low", label = "Super · Low", classPwMin = 0.3638, classPwMax = 0.4079, pickWeight = 1 },
  { branch = "super", id = "super_track_mid", label = "Super · Mid", classPwMin = 0.3858, classPwMax = 0.4365, pickWeight = 1 },
  { branch = "super", id = "super_track_high", label = "Super · High", classPwMin = 0.4145, classPwMax = 0.4740, pickWeight = 1 },
  -- Above super_track_high: without this row, getSanctionedPwBracketLabelForPw / getSanctionedBranchForPw fall through and UI/offers stick to stale "stock" / stock branch.
  { branch = "open", id = "open_unlimited", label = OPEN_SANCTIONED_BRACKET_LABEL, classPwMin = OPEN_SANCTIONED_PW_MIN, classPwMax = OPEN_SANCTIONED_PW_MAX, pickWeight = 1 },
}

local cachedLevelId = nil
local cachedCfg = nil
local runtime = {
  suppressFrePayouts = false,
  podiumEligible = { result = false },
  dispatchUiActive = false,
}

--- Verbose trace for racing-team / sanctioned freeroam HUD mismatches. Set to false to silence.
local SR_TRACE_BEGIN = true

local function srTrace(msg)
  if not SR_TRACE_BEGIN then
    return
  end
  log("I", "sanctionedRacing", msg)
end

local function commitExternalFail(err)
  if SR_TRACE_BEGIN then
    log("I", "sanctionedRacing", "commitAndNavigateExternalOffer FAIL: " .. tostring(err))
  end
  return false, err
end

--- Called from freeroamEvents.beginFreeroamRace so logs show the bridge before onRaceBegin.
function M.traceBeginFromFreeroam(raceNameArg)
  srTrace("beginFreeroamRace -> onRaceBegin next, raceNameArg=" .. tostring(raceNameArg))
end

function M.traceBeginFromFreeroamEarlyExitNoRace(raceNameArg)
  srTrace("beginFreeroamRace early exit: no session.races entry for raceNameArg=" .. tostring(raceNameArg))
end

local mCelebrationRewards = nil

local function defaultCfgSlice()
  return {
    variants = {},
    sanctionedRaceNames = {},
    defaultOfferRefreshMinutes = 20,
    defaultStartDeadlineMinutes = 60,
  }
end

local function normalizeRouteType(rt)
  if type(rt) ~= "string" then
    return "main"
  end
  if string.lower(rt) == "alt" then
    return "alt"
  end
  return "main"
end

local function getRaceDataTable(levelId)
  local rCache = gameplay_events_freContracts_raceCache
  if rCache and rCache.getRawRaceData then
    local data = rCache.getRawRaceData(levelId)
    if type(data) == "table" then
      return data
    end
  end
  if type(levelId) ~= "string" or levelId == "" then
    return nil
  end
  local data = jsonReadFile("levels/" .. levelId .. "/race_data.json")
  return type(data) == "table" and data or nil
end

local function readRaceRewardInputs(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = getRaceDataTable(levelId)
  if type(data) ~= "table" then
    return nil
  end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then
    return nil
  end
  local goalTime, baseReward
  if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
    goalTime = tonumber(race.altRoute.bestTime)
    baseReward = tonumber(race.altRoute.reward)
  else
    goalTime = tonumber(race.bestTime)
    baseReward = tonumber(race.reward)
  end
  if not goalTime or goalTime <= 0 or not baseReward or baseReward <= 0 then
    return nil
  end
  return goalTime, baseReward, race
end

local function getRaceRewardAtTargetTime(levelId, raceName, routeType)
  local goalTime, baseReward, race = readRaceRewardInputs(levelId, raceName, routeType)
  if not goalTime then
    return nil
  end
  local u = gameplay_events_freeroam_utils
  if not u or not u.raceReward then
    return nil
  end
  return u.raceReward(goalTime, baseReward, goalTime, race.type)
end

local function getRaceLapCount(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = getRaceDataTable(levelId)
  if type(data) ~= "table" then
    return nil
  end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then
    return nil
  end
  local r = race
  if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
    r = race.altRoute
  end
  local lc = tonumber(r.lapCount)
  if lc and lc > 0 then
    return math.floor(lc)
  end
  return nil
end

local function getRaceBestTimeSeconds(levelId, raceName, routeType)
  if type(levelId) ~= "string" or levelId == "" or type(raceName) ~= "string" or raceName == "" then
    return nil
  end
  local data = getRaceDataTable(levelId)
  if type(data) ~= "table" then
    return nil
  end
  local race = (data.races or {})[raceName]
  if type(race) ~= "table" then
    return nil
  end
  if normalizeRouteType(routeType) == "alt" and type(race.altRoute) == "table" then
    local t = tonumber(race.altRoute.bestTime)
    return (t and t > 0) and t or nil
  end
  local t = tonumber(race.bestTime)
  return (t and t > 0) and t or nil
end

local function getDisciplineIdsFromRace(race)
  local disciplineIds = {}
  local seen = {}
  if type(race) ~= "table" then
    return disciplineIds
  end
  for _, rawType in ipairs(race.type or {}) do
    local disciplineId = freConfig.getDisciplineIdFromType(rawType)
    if disciplineId and not seen[disciplineId] then
      seen[disciplineId] = true
      table.insert(disciplineIds, disciplineId)
    end
  end
  return disciplineIds
end

local function getClassPayoutMultiplier(branch, overrides)
  local key = type(branch) == "string" and string.lower(branch) or ""
  local tab = type(overrides) == "table" and overrides or nil
  if tab and tab[key] ~= nil then
    local v = tonumber(tab[key])
    if v and v > 0 then
      return v
    end
  end
  local d = DEFAULT_CLASS_PAYOUT_MULT[key]
  if type(d) == "number" and d > 0 then
    return d
  end
  return 1
end

local function podiumMultFromTable(t, key, defaultVal)
  local tab = type(t) == "table" and t or {}
  local v = tonumber(tab[key])
  if v == nil then
    return defaultVal
  end
  return math.max(0, v)
end

local function computePodiumPayouts(baseMoney, variant)
  local helpers = gameplay_events_freContracts_helpers
  local pm = variant.podiumMultipliers
  local m1 = podiumMultFromTable(pm, "first", DEFAULT_PODIUM_MULT.first)
  local m2 = podiumMultFromTable(pm, "second", DEFAULT_PODIUM_MULT.second)
  local m3 = podiumMultFromTable(pm, "third", DEFAULT_PODIUM_MULT.third)
  local pv = variant.podiumVariance
  local vmin = math.max(0.1, tonumber(pv and pv.min) or DEFAULT_PODIUM_VARIANCE.min)
  local vmax = math.max(vmin, tonumber(pv and pv.max) or DEFAULT_PODIUM_VARIANCE.max)
  local bundle = helpers.randomFloat(vmin, vmax)
  local function placePayout(mult)
    local j = helpers.randomFloat(PLACE_JITTER.min, PLACE_JITTER.max)
    return math.max(0, math.floor(baseMoney * mult * bundle * j + 0.5))
  end
  local p1 = placePayout(m1)
  local p2 = placePayout(m2)
  local p3 = placePayout(m3)
  return p1, p2, p3
end

local function roundPw4(x)
  local n = tonumber(x)
  if not n then
    return 0
  end
  return math.floor(n * 10000 + 0.5) / 10000
end

--- hp/kg brackets: classPwMin / classPwMax (aiRacingConfig hpBrackets uses same keys).
local function normalizeSanctionedPwBrackets(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, b in ipairs(list) do
    if type(b) == "table" then
      local lo = roundPw4(b.classPwMin)
      local hi = roundPw4(b.classPwMax)
      if hi < lo then
        lo, hi = hi, lo
      end
      local w = tonumber(b.pickWeight)
      if w == nil then
        w = 1
      end
      w = math.max(0, w)
      if w > 0 and hi >= lo then
        table.insert(out, {
          branch = type(b.branch) == "string" and b.branch or nil,
          id = type(b.id) == "string" and b.id or nil,
          label = type(b.label) == "string" and b.label or nil,
          classPwMin = lo,
          classPwMax = hi,
          pickWeight = w,
        })
      end
    end
  end
  return out
end

local function pickWeightedFromList(entries)
  local helpers = gameplay_events_freContracts_helpers
  local total = 0
  for _, v in ipairs(entries) do
    total = total + (tonumber(v.pickWeight) or 0)
  end
  if total <= 0 then
    return nil
  end
  local roll = helpers.randomFloat(0, total)
  local running = 0
  for _, v in ipairs(entries) do
    running = running + (tonumber(v.pickWeight) or 0)
    if roll < running then
      return v
    end
  end
  return entries[#entries]
end

local function collectSanctionedVariants(raw, disciplineId)
  local list = {}
  if type(raw) ~= "table" or type(raw.byRace) ~= "table" then
    return list
  end
  local wantDisc = string.lower(tostring(disciplineId or ""))
  for pathKey, entry in pairs(raw.byRace) do
    if type(pathKey) == "string" and type(entry) == "table" then
      local s = entry.sanctioned
      if type(s) == "table" and s.enabled ~= false then
        local sd = string.lower(tostring(s.disciplineId or DISCIPLINE_ROAD))
        if sd == wantDisc then
          local w = tonumber(s.pickWeight)
          if w == nil then
            w = 1
          end
          w = math.max(0, w)
          local rn = type(s.raceName) == "string" and s.raceName ~= "" and s.raceName or nil
          if w > 0 and rn then
            table.insert(list, {
              pathKey = pathKey,
              raceName = rn,
              routeType = normalizeRouteType(s.routeType),
              pickWeight = w,
              stageNumber = tonumber(s.stageNumber) or nil,
              hpBrackets = type(s.hpBrackets) == "table" and s.hpBrackets or nil,
              podiumMultipliers = type(s.podiumMultipliers) == "table" and s.podiumMultipliers or nil,
              podiumVariance = type(s.podiumVariance) == "table" and s.podiumVariance or nil,
              classPayoutMultipliers = type(s.classPayoutMultipliers) == "table" and s.classPayoutMultipliers or nil,
              offerRefreshMinutes = s.offerRefreshMinutes,
              startDeadlineMinutes = s.startDeadlineMinutes,
            })
          end
        end
      end
    end
  end
  return list
end

local function pickWeightedVariant(variants)
  return pickWeightedFromList(variants)
end

local function filterVariantsByRouteBucket(variants, routeBucket)
  if type(variants) ~= "table" or #variants == 0 then
    return variants
  end
  local bucket = type(routeBucket) == "string" and string.lower(routeBucket) or ""
  if bucket ~= "short" and bucket ~= "track" then
    return variants
  end
  local filtered = {}
  for _, v in ipairs(variants) do
    local rt = normalizeRouteType(v.routeType)
    if bucket == "short" and rt == "alt" then
      table.insert(filtered, v)
    elseif bucket == "track" and rt ~= "alt" then
      table.insert(filtered, v)
    end
  end
  if #filtered > 0 then
    return filtered
  end
  return variants
end

--- options.bracketPick: "fleet_pw" | "above_fleet_pw" (needs options.pwReference); default weighted random.
local function pickBracketForRollOptions(brackets, options)
  if type(brackets) ~= "table" or #brackets == 0 then
    return nil
  end
  local pick = type(options) == "table" and options.bracketPick or nil
  local pw = type(options) == "table" and tonumber(options.pwReference) or nil
  if pick == "fleet_pw" and pw and pw > 0 then
    local matches = {}
    for _, b in ipairs(brackets) do
      local lo = tonumber(b.classPwMin) or 0
      local hi = tonumber(b.classPwMax) or lo
      if pw >= lo and pw <= hi then
        table.insert(matches, b)
      end
    end
    if #matches > 0 then
      table.sort(matches, function(a, b)
        return (tonumber(a.classPwMin) or 0) > (tonumber(b.classPwMin) or 0)
      end)
      return matches[1]
    end
    local best, bestLo = nil, -1e9
    for _, b in ipairs(brackets) do
      local lo = tonumber(b.classPwMin) or 0
      local hi = tonumber(b.classPwMax) or lo
      if pw <= hi and lo > bestLo then
        bestLo = lo
        best = b
      end
    end
    if best then
      return best
    end
  elseif pick == "above_fleet_pw" and pw and pw > 0 then
    local best, bestLo = nil, 1e9
    for _, b in ipairs(brackets) do
      local lo = tonumber(b.classPwMin) or 0
      if lo > pw and lo < bestLo then
        bestLo = lo
        best = b
      end
    end
    if best then
      return best
    end
    local top = brackets[1]
    for _, b in ipairs(brackets) do
      if (tonumber(b.classPwMin) or 0) > (tonumber(top.classPwMin) or 0) then
        top = b
      end
    end
    return top
  end
  return pickWeightedFromList(brackets)
end

local function loadCfgForLevel(levelId)
  levelId = type(levelId) == "string" and levelId or ""
  if cachedLevelId == levelId and cachedCfg then
    return cachedCfg
  end
  cachedLevelId = levelId
  cachedCfg = defaultCfgSlice()
  if levelId == "" then
    return cachedCfg
  end
  local path = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. CONFIG_RACE_FILENAME
  local raw = jsonReadFile(path)
  if type(raw) ~= "table" then
    return cachedCfg
  end
  cachedCfg.variants = collectSanctionedVariants(raw, DISCIPLINE_ROAD)
  cachedCfg.sanctionedRaceNames = {}
  for _, v in ipairs(cachedCfg.variants) do
    if type(v.raceName) == "string" and v.raceName ~= "" then
      cachedCfg.sanctionedRaceNames[v.raceName] = true
    end
  end
  if #cachedCfg.variants > 0 then
    local v0 = cachedCfg.variants[1]
    cachedCfg.defaultOfferRefreshMinutes =
      math.max(0.25, tonumber(v0.offerRefreshMinutes) or cachedCfg.defaultOfferRefreshMinutes)
    cachedCfg.defaultStartDeadlineMinutes =
      math.max(1, tonumber(v0.startDeadlineMinutes) or cachedCfg.defaultStartDeadlineMinutes)
  end
  return cachedCfg
end

local function loadCfg()
  return loadCfgForLevel(gameplay_events_freContracts_state.getCurrentLevelId() or "")
end

local function isSanctionedRaceNameConfigured(raceName)
  if type(raceName) ~= "string" or raceName == "" then
    return false
  end
  local cfg = loadCfg()
  local s = cfg.sanctionedRaceNames
  return type(s) == "table" and s[raceName] == true
end

local function hasSanctionedForRoadRacing()
  return #loadCfg().variants > 0
end

--- options.branchFilter: e.g. "stock" — only HP brackets with that branch (after normalize).
local function rollOfferForVariantAtLevel(levelId, variant, disciplineId, now, allocOfferId, options)
  if type(allocOfferId) ~= "function" or type(variant) ~= "table" then
    return nil
  end
  levelId = type(levelId) == "string" and levelId or ""
  local cfg = loadCfgForLevel(levelId)
  local rCache = gameplay_events_freContracts_raceCache
  local raceEntry = rCache.findRaceEntry(disciplineId, variant.raceName, variant.routeType, nil)
  if not raceEntry then
    raceEntry = rCache.findRaceEntry(disciplineId, variant.raceName, "main", nil)
  end
  if not raceEntry then
    return nil
  end
  local goalTime, rawTabularReward, raceRow = readRaceRewardInputs(levelId, variant.raceName, variant.routeType)
  if not goalTime then
    return nil
  end
  local uFre = gameplay_events_freeroam_utils
  if not uFre or not uFre.raceReward then
    return nil
  end
  local baseMoney = uFre.raceReward(goalTime, rawTabularReward, goalTime, raceRow.type)
  if not baseMoney or baseMoney <= 0 then
    return nil
  end
  local bracketSrc = variant.hpBrackets
  if type(bracketSrc) ~= "table" or #bracketSrc == 0 then
    bracketSrc = DEFAULT_SANCTIONED_PW_BRACKETS
  end
  local brackets = normalizeSanctionedPwBrackets(bracketSrc)
  if type(options) == "table" and type(options.branchFilter) == "string" and options.branchFilter ~= "" then
    local bf = string.lower(options.branchFilter)
    local filtered = {}
    for _, b in ipairs(brackets) do
      if string.lower(tostring(b.branch or "")) == bf then
        table.insert(filtered, b)
      end
    end
    if #filtered > 0 then
      brackets = filtered
    end
  end
  if #brackets == 0 then
    return nil
  end
  local br = pickBracketForRollOptions(brackets, options)
  if not br then
    return nil
  end
  local refMin = br.classPwMin
  local refMax = br.classPwMax
  local classPayMult = getClassPayoutMultiplier(br.branch, variant.classPayoutMultipliers)
  local helpers = gameplay_events_freContracts_helpers
  local refLaps = getRaceLapCount(levelId, variant.raceName, variant.routeType) or 3
  local bestTime = getRaceBestTimeSeconds(levelId, variant.raceName, variant.routeType)
  local lapCount = refLaps
  local lapScale = 1
  if type(bestTime) == "number" and bestTime > 0 and helpers and helpers.randomInt then
    local maxLaps = math.floor(SANCTIONED_MAX_WINDOW_SEC / bestTime)
    maxLaps = math.max(SANCTIONED_MIN_LAP_COUNT, math.min(maxLaps, SANCTIONED_LAP_ROLL_CAP))
    lapCount = helpers.randomInt(SANCTIONED_MIN_LAP_COUNT, maxLaps)
    lapScale = lapCount / refLaps
  end
  if lapCount < SANCTIONED_MIN_LAP_COUNT then
    lapCount = SANCTIONED_MIN_LAP_COUNT
    lapScale = lapCount / refLaps
  end
  -- Economy + difficulty cash scaling: only via gameplay_events_freeroam_utils.race_reward (economy adjuster + job market;
  -- difficulty preset syncs adjuster in career_modules_difficultyMode.applyEconomyPreset). No second reward mult here.
  local preClassLapMoney = baseMoney * classPayMult * lapScale
  local freSkillSponsorMoneyMult = 1
  if gameplay_events_freContracts_race and gameplay_events_freContracts_race.calculateRewardModifiers then
    local mods = gameplay_events_freContracts_race.calculateRewardModifiers(getDisciplineIdsFromRace(raceRow))
    if type(mods) == "table" then
      freSkillSponsorMoneyMult = tonumber(mods.moneyMultiplier) or 1
    end
  end
  local prePodiumMoney = preClassLapMoney * freSkillSponsorMoneyMult
  local scaledBase = prePodiumMoney
  local p1, p2, p3 = computePodiumPayouts(scaledBase, variant)
  local xp1, xp2, xp3 = moneyToSanctionedXp(p1), moneyToSanctionedXp(p2), moneyToSanctionedXp(p3)
  local refresh = math.max(0.25, tonumber(variant.offerRefreshMinutes) or cfg.defaultOfferRefreshMinutes)
  local deadline = math.max(1, tonumber(variant.startDeadlineMinutes) or cfg.defaultStartDeadlineMinutes)
  local stageNum = tonumber(variant.stageNumber)
  if stageNum == nil or stageNum < 1 then
    stageNum = 1
  end
  stageNum = math.floor(stageNum)
  return {
    id = allocOfferId(),
    disciplineId = disciplineId,
    raceName = raceEntry.raceName,
    raceLabel = raceEntry.raceLabel,
    stageNumber = stageNum,
    raceRouteType = raceEntry.routeType or variant.routeType,
    sanctionedPathKey = variant.pathKey,
    hpBracketId = br.id,
    hpBracketBranch = br.branch,
    hpBracketLabel = br.label,
    hpBracketPayoutMult = classPayMult,
    classPwMin = refMin,
    classPwMax = refMax,
    lapCount = lapCount,
    payoutFirst = p1,
    payoutSecond = p2,
    payoutThird = p3,
    xpFirst = xp1,
    xpSecond = xp2,
    xpThird = xp3,
    phase = "available",
    createdAt = now,
    visibleExpiresAt = now + refresh,
    startDeadlineMinutes = deadline,
    committedAt = nil,
    startDeadlineAt = nil,
  }
end

local function rollOfferForDisciplineAtLevel(levelId, disciplineId, now, allocOfferId, options)
  if type(allocOfferId) ~= "function" then
    return nil
  end
  levelId = type(levelId) == "string" and levelId or ""
  local cfg = loadCfgForLevel(levelId)
  local variants = cfg.variants
  if #variants == 0 then
    return nil
  end
  if type(options) == "table" and options.routeBucket then
    variants = filterVariantsByRouteBucket(variants, options.routeBucket)
  end
  local variant = pickWeightedVariant(variants)
  if not variant then
    return nil
  end
  return rollOfferForVariantAtLevel(levelId, variant, disciplineId, now, allocOfferId, options)
end

local function rollOfferForDiscipline(disciplineId, now)
  local levelId = gameplay_events_freContracts_state.getCurrentLevelId() or ""
  return rollOfferForDisciplineAtLevel(levelId, disciplineId, now, function()
    return gameplay_events_freContracts_state.nextId("fre-sanctioned")
  end, nil)
end

--- Same rolling logic as phone sanctioned offers, for a specific level (e.g. racing team business computer).
--- options: branchFilter, routeBucket ("track"|"short"), bracketPick ("fleet_pw"|"above_fleet_pw"), pwReference (hp/kg).
function M.rollRacingTeamSanctionedOffer(levelId, disciplineId, now, options)
  if type(levelId) ~= "string" or levelId == "" then
    return nil
  end
  local disc = type(disciplineId) == "string" and disciplineId ~= "" and disciplineId or DISCIPLINE_ROAD
  local n = tonumber(now)
  if not n then
    n = 0
  end
  return rollOfferForDisciplineAtLevel(levelId, disc, n, function()
    return gameplay_events_freContracts_state.nextId("rt-race-offer")
  end, options)
end

--- Racing team league1 (tier 1): one sanctioned offer per configured track/route (deduped by raceName + routeType).
--- branchFilter: optional "stock"|"modified"|"super"|"open" (default "stock") — match team hp/kg via getSanctionedBranchForPw.
function M.buildRacingTeamLeague1StockOffers(levelId, now, branchFilter)
  if type(levelId) ~= "string" or levelId == "" then
    return {}
  end
  local n = tonumber(now)
  if not n then
    n = 0
  end
  local bf = type(branchFilter) == "string" and branchFilter ~= "" and string.lower(branchFilter) or "stock"
  local cfg = loadCfgForLevel(levelId)
  local variants = cfg.variants
  if #variants == 0 then
    return {}
  end
  local seen = {}
  local out = {}
  for _, variant in ipairs(variants) do
    local key = string.lower(tostring(variant.raceName or "")) .. "\0" .. string.lower(tostring(variant.routeType or ""))
    if not seen[key] then
      seen[key] = true
      local o = rollOfferForVariantAtLevel(levelId, variant, DISCIPLINE_ROAD, n, function()
        return gameplay_events_freContracts_state.nextId("rt-race-offer")
      end, { branchFilter = bf })
      if o then
        table.insert(out, o)
      end
    end
  end
  return out
end

local function ensureSrState(state)
  if not state.sanctionedRacing or type(state.sanctionedRacing) ~= "table" then
    state.sanctionedRacing = { offer = nil, nextGenAt = 0 }
  end
  local sr = state.sanctionedRacing
  if sr.offer ~= nil and type(sr.offer) ~= "table" then
    sr.offer = nil
  end
  sr.nextGenAt = tonumber(sr.nextGenAt) or 0
  return sr
end

local function skillOk(disciplineId)
  local need = freConfig.getSanctionedRacingUnlockLevel()
  local level = gameplay_events_freContracts_skills.getSkillLevel(disciplineId)
  if level < need then return false end
  local tiers = gameplay_events_freContracts_skills.getUnlockedContractTiers(disciplineId, level)
  return #tiers > 0
end

--- Racing-team / league1 external commits must survive sync ticks where getCurrentLevelId() is
--- briefly nil or loadCfg() has no variants (hasSanctionedForRoadRacing false) — otherwise sr.offer
--- is wiped before onRaceBegin (phase="committed") or, worse, mid-race (phase="racing") leaving the
--- HUD armed but settleFromAiResults with a nil offer → no podium credit and $0 payout.
local function shouldPreserveTeamOfferDuringSanctionedMapSync(offer)
  if type(offer) ~= "table" then return false end
  if offer.racingTeamBusinessOffer ~= true and offer.league1PlayerRace ~= true then return false end
  local phase = offer.phase
  return phase == "committed" or phase == "racing" or phase == "available"
end

function M.syncGeneration(now)
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local changed = false
  local n = tonumber(now) or state.simTime or 0

  if not skillOk(DISCIPLINE_ROAD) then
    sr.lastSkillGateOk = false
    if sr.offer and not shouldPreserveTeamOfferDuringSanctionedMapSync(sr.offer) then
      srTrace(string.format(
        "syncGeneration CLEAR (skill gate) phase=%s teamOffer=%s league1=%s",
        tostring(sr.offer.phase),
        tostring(sr.offer.racingTeamBusinessOffer == true),
        tostring(sr.offer.league1PlayerRace == true)))
      sr.offer = nil
      sr.nextGenAt = 0
      changed = true
    end
    return changed
  end

  if not hasSanctionedForRoadRacing() then
    if sr.offer and not shouldPreserveTeamOfferDuringSanctionedMapSync(sr.offer) then
      srTrace(string.format(
        "syncGeneration CLEAR (no sanctioned for road) phase=%s teamOffer=%s league1=%s",
        tostring(sr.offer.phase),
        tostring(sr.offer.racingTeamBusinessOffer == true),
        tostring(sr.offer.league1PlayerRace == true)))
      sr.offer = nil
      sr.nextGenAt = 0
      changed = true
    end
    -- A zero/expired nextGenAt used to leave the maintenance scheduler due on
    -- every frame when the current map had no sanctioned road-racing variants.
    -- Keep a short retry so newly available route data is still discovered,
    -- without rebuilding every contract offer table at render frequency.
    if not sr.offer and n >= (tonumber(sr.nextGenAt) or 0) then
      sr.nextGenAt = n + 1
      changed = true
    end
    return changed
  end

  do
    local prev = sr.lastSkillGateOk
    if prev == nil then
      prev = true
    end
    local justUnlocked = (prev == false)
    sr.lastSkillGateOk = true
    if justUnlocked and not sr.offer then
      local newOffer = rollOfferForDiscipline(DISCIPLINE_ROAD, n)
      if newOffer then
        sr.offer = newOffer
        sr.nextGenAt = newOffer.visibleExpiresAt
      else
        sr.nextGenAt = n + 0.5
      end
      changed = true
    end
  end

  local offer = sr.offer
  -- Racing-team / external commits can sit on grid staging for a long wall time; do not expire them
  -- via the phone-offer start deadline (small startDeadlineMinutes == few simTime units).
  local skipCommitDeadline =
    offer and (offer.racingTeamBusinessOffer == true or offer.league1PlayerRace == true)
  if not skipCommitDeadline and offer and offer.phase == "committed" and (tonumber(offer.startDeadlineAt) or 0) > 0
      and n >= offer.startDeadlineAt then
    sr.offer = nil
    local cfgDl = loadCfg()
    sr.nextGenAt = n + math.max(0.5, tonumber(cfgDl.defaultOfferRefreshMinutes) or 12)
    changed = true
    offer = nil
  end

  if offer and offer.phase == "available" and n >= (tonumber(offer.visibleExpiresAt) or 0) then
    local newOffer = rollOfferForDiscipline(DISCIPLINE_ROAD, n)
    if newOffer then
      sr.offer = newOffer
      sr.nextGenAt = newOffer.visibleExpiresAt
    else
      sr.offer = nil
      sr.nextGenAt = n + 0.5
    end
    changed = true
    offer = sr.offer
  end

  if not sr.offer and n >= (tonumber(sr.nextGenAt) or 0) then
    local cfg = loadCfg()
    local newOffer = rollOfferForDiscipline(DISCIPLINE_ROAD, n)
    if newOffer then
      sr.offer = newOffer
      sr.nextGenAt = newOffer.visibleExpiresAt
    else
      sr.nextGenAt = n + math.max(1, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
    end
    changed = true
  end

  return changed
end

local function getCompetitiveTrackFlow()
  local c = gameplay_events_freeroam_competitiveTrackFlow
  if c then
    return c
  end
  if extensions and extensions["gameplay_events_freeroam_competitiveTrackFlow"] then
    return extensions["gameplay_events_freeroam_competitiveTrackFlow"]
  end
  return nil
end

--- Reference curb weight (kg) for converting sanctioned P/W bracket → HP numbers on the phone / UI.
local function playerRefWeightKgForOfferDisplay()
  local ar = rawget(_G, "career_modules_competitiveRace_aiRacers")
  if ar and type(ar.getPlayerVehicleWeightKg) == "function" then
    local w = ar.getPlayerVehicleWeightKg()
    if type(w) == "number" and w > 0 then
      return w
    end
  end
  return nil
end

--- Player HP for offer/staging readouts: live dyno-style sample when trusted, else sync (matches competitiveTrackFlow staging payload).
local function playerCatalogHpForOfferDisplay()
  local ar = rawget(_G, "career_modules_competitiveRace_aiRacers")
  if ar and type(ar.getPlayerVehiclePowerForStagingUi) == "function" then
    local hp = select(1, ar.getPlayerVehiclePowerForStagingUi())
    if type(hp) == "number" and hp > 0 then
      return math.floor(hp + 0.5)
    end
  end
  if ar and type(ar.getPlayerVehiclePower) == "function" then
    local hp = ar.getPlayerVehiclePower()
    if type(hp) == "number" and hp > 0 then
      return math.floor(hp + 0.5)
    end
  end
  return nil
end

--- HP range implied by hp/kg class limits at the given curb weight (display only; bracket logic stays P/W).
local function displayHpBandFromPwBracket(pwMin, pwMax, wkg)
  if not wkg or wkg <= 0 then
    return nil, nil, nil
  end
  local lo = tonumber(pwMin)
  local hi = tonumber(pwMax)
  if not lo or not hi then
    return nil, nil, nil
  end
  return math.floor(lo * wkg + 0.5), math.floor(hi * wkg + 0.5), wkg
end

--- Mutates offer table in-place with displayClassHpMin/Max for business board payloads (optional).
function M.attachSanctionedOfferDisplayHp(offer)
  if type(offer) ~= "table" then
    return
  end
  local wkg = playerRefWeightKgForOfferDisplay()
  local dmin, dmax, dbg = displayHpBandFromPwBracket(offer.classPwMin, offer.classPwMax, wkg)
  offer.displayClassHpMin = dmin
  offer.displayClassHpMax = dmax
  offer.displayHpBasisWeightKg = dbg
end

function M.getOfferUiSnapshot(now)
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local n = tonumber(now) or state.simTime or 0
  local offer = sr.offer
  if not offer then
    return nil
  end
  local useAlt = string.lower(tostring(offer.raceRouteType or "main")) == "alt"
  local dispatchActive = false
  if offer.phase == "committed" then
    if runtime.dispatchUiActive == true then
      dispatchActive = true
    end
    local ctf = getCompetitiveTrackFlow()
    if ctf and ctf.isSanctionedCareerGoToRaceActive and ctf.isSanctionedCareerGoToRaceActive() then
      dispatchActive = true
    end
  end
  local wkg = playerRefWeightKgForOfferDisplay()
  local dmin, dmax, dbg = displayHpBandFromPwBracket(offer.classPwMin, offer.classPwMax, wkg)
  local playerHp = playerCatalogHpForOfferDisplay()
  return {
    id = offer.id,
    disciplineId = offer.disciplineId,
    raceName = offer.raceName,
    raceLabel = offer.raceLabel,
    stageNumber = tonumber(offer.stageNumber) or 1,
    raceRouteType = offer.raceRouteType,
    useAltRoute = useAlt,
    hpBracketId = offer.hpBracketId,
    hpBracketBranch = offer.hpBracketBranch,
    hpBracketLabel = offer.hpBracketLabel,
    hpBracketPayoutMult = offer.hpBracketPayoutMult,
    classPwMin = offer.classPwMin,
    classPwMax = offer.classPwMax,
    displayClassHpMin = dmin,
    displayClassHpMax = dmax,
    displayHpBasisWeightKg = dbg,
    playerCatalogHp = playerHp,
    lapCount = tonumber(offer.lapCount) or 3,
    payoutFirst = offer.payoutFirst,
    payoutSecond = offer.payoutSecond,
    payoutThird = offer.payoutThird,
    xpFirst = offer.xpFirst,
    xpSecond = offer.xpSecond,
    xpThird = offer.xpThird,
    phase = offer.phase,
    minutesUntilRefresh = math.max(0, (tonumber(offer.visibleExpiresAt) or n) - n),
    minutesUntilStartDeadline = (offer.phase == "committed" and offer.startDeadlineAt) and
      math.max(0, offer.startDeadlineAt - n) or nil,
    dispatchActive = dispatchActive,
  }
end

function M.isSanctionedRescheduleActionActive()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or o.phase ~= "committed" then
    return false
  end
  if runtime.dispatchUiActive == true then
    return true
  end
  local ctf = getCompetitiveTrackFlow()
  if ctf and ctf.isSanctionedCareerGoToRaceActive and ctf.isSanctionedCareerGoToRaceActive() then
    return true
  end
  return false
end

function M.isSanctionedRaceDispatchActive()
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  return o and (o.phase == "committed" or o.phase == "racing") or false
end

local function poolRefPwFromOffer(offer)
  if not offer then return nil end
  local hi = tonumber(offer.classPwMax)
  if type(hi) ~= "number" or hi <= 0 then
    return nil
  end
  return hi
end

local function pushDispatchForOffer(offer)
  if not offer then return end
  local fe = gameplay_events_freeroamEvents
  if fe and fe.startSanctionedRaceDispatch then
    fe.startSanctionedRaceDispatch(string.lower(tostring(offer.raceRouteType or "main")) == "alt", poolRefPwFromOffer(offer))
  end
end

local function validateSanctionedOfferAvailable(offer)
  if not offer or offer.phase ~= "available" then
    return false, "No open offer to commit to."
  end
  if type(offer.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offer.raceName) then
    return false, "Unsupported sanctioned race."
  end
  return true, nil
end

function M.commitSanctionedRace()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false, "Career not active."
  end
  if not skillOk(DISCIPLINE_ROAD) then
    return false, "Road Racing level 15 and an Easy license are required."
  end
  if not hasSanctionedForRoadRacing() then
    return false, "No sanctioned racing on this map."
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  local ok, err = validateSanctionedOfferAvailable(offer)
  if not ok then
    return false, err
  end
  local n = state.simTime or 0
  local cfg = loadCfg()
  local deadlineMin = math.max(1, tonumber(offer.startDeadlineMinutes) or tonumber(cfg.defaultStartDeadlineMinutes) or 60)
  offer.phase = "committed"
  offer.committedAt = n
  offer.startDeadlineAt = n + deadlineMin
  sr.nextGenAt = offer.startDeadlineAt
  runtime.dispatchUiActive = false
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(n)
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_commit")
  career_saveSystem.saveCurrent()
  return true, nil
end

function M.navigateSanctionedRace()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false, "Career not active."
  end
  if not skillOk(DISCIPLINE_ROAD) then
    return false, "Road Racing level 15 and an Easy license are required."
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer or (offer.phase ~= "committed" and offer.phase ~= "racing") then
    return false, "Commit to a race first."
  end
  if type(offer.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offer.raceName) then
    return false, "Unsupported sanctioned race."
  end
  pushDispatchForOffer(offer)
  runtime.dispatchUiActive = true
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_navigate")
  return true, nil
end

--- Inject and start a sanctioned-style race from an external offer source (e.g. racing team league1).
--- opts: { bypassSkillGate = true|false }
function M.commitAndNavigateExternalOffer(offerIn, opts)
  if not gameplay_events_freContracts_state.isCareerActive() then
    return commitExternalFail("Career not active.")
  end
  if type(offerIn) ~= "table" then
    return commitExternalFail("Missing offer.")
  end
  local bypassSkillGate = type(opts) == "table" and opts.bypassSkillGate == true
  if not bypassSkillGate and not skillOk(DISCIPLINE_ROAD) then
    return commitExternalFail("Road Racing level 15 and an Easy license are required.")
  end
  if not hasSanctionedForRoadRacing() then
    return commitExternalFail("No sanctioned racing on this map.")
  end
  if type(offerIn.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offerIn.raceName) then
    return commitExternalFail("Unsupported sanctioned race.")
  end

  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local existing = sr.offer
  if existing and existing.phase == "racing" then
    return commitExternalFail("Finish or abort the race first.")
  end
  if existing and existing.phase == "committed" then
    return commitExternalFail("A sanctioned race is already committed.")
  end

  -- Block player from entering a league-2+ player-alongside-proxy team race
  -- while their post-race cooldown is still ticking. Per-vehicle and
  -- per-driver cooldowns are gated separately; this check guards the player
  -- specifically and only applies to the new league-2+ flow (league 1 player
  -- races keep prior gameplay).
  if offerIn.playerProxyAlongsideRace == true and offerIn.businessId ~= nil then
    local rt = rawget(_G, "career_modules_business_racingTeam")
    if rt and rt.getPlayerPostRaceCooldownRemainingSec then
      local rem = tonumber(rt.getPlayerPostRaceCooldownRemainingSec(offerIn.businessId)) or 0
      if rem > 0 then
        local mins = math.ceil(rem / 60)
        return commitExternalFail(string.format("Player cooldown active (%d min remaining).", mins))
      end
    end
  end

  local n = state.simTime or 0
  local cfg = loadCfg()
  local out = {}
  for k, v in pairs(offerIn) do
    out[k] = v
  end
  out.disciplineId = out.disciplineId or DISCIPLINE_ROAD
  out.phase = "committed"
  out.committedAt = n
  local deadlineMin = math.max(1, tonumber(out.startDeadlineMinutes) or tonumber(cfg.defaultStartDeadlineMinutes) or 60)
  -- Board offers can carry small startDeadlineMinutes; simTime is coarse (see freContracts state.updateSimTime).
  if out.racingTeamBusinessOffer == true then
    deadlineMin = math.max(60, deadlineMin)
  end
  out.startDeadlineAt = n + deadlineMin
  sr.offer = out
  sr.nextGenAt = out.startDeadlineAt

  runtime.dispatchUiActive = false
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(n)
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_commit_external")
  career_saveSystem.saveCurrent()

  pushDispatchForOffer(out)
  runtime.dispatchUiActive = true
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_navigate_external")
  srTrace(string.format(
    "commitAndNavigateExternalOffer OK id=%s raceName=%s teamOffer=%s lapCount=%s",
    tostring(out.id),
    tostring(out.raceName),
    tostring(out.racingTeamBusinessOffer == true),
    tostring(out.lapCount)
  ))
  return true, nil
end

function M.rescheduleSanctionedRace()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false, "Career not active."
  end
  if not skillOk(DISCIPLINE_ROAD) then
    return false, "Road Racing level 15 and an Easy license are required."
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer or type(offer.raceName) ~= "string" or not isSanctionedRaceNameConfigured(offer.raceName) then
    return false, "No sanctioned race."
  end
  if offer.phase == "racing" then
    return false, "Finish or abort the race first."
  end
  if offer.phase ~= "committed" then
    return false, "Commit to a race first."
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if ctf then
    if ctf.clearSanctionedParkingStagingUi then
      ctf.clearSanctionedParkingStagingUi()
    end
    if ctf.cancelCompetitiveGridFlow then
      ctf.cancelCompetitiveGridFlow()
    end
    if ctf.leaveTrackFlowAfterRace then
      ctf.leaveTrackFlowAfterRace()
    end
  end
  local aiRacers = gameplay_events_freeroam_aiRacers
  if aiRacers and aiRacers.clearSpawned then
    aiRacers.clearSpawned()
  end
  local fe = gameplay_events_freeroamEvents
  if fe and fe.clearSanctionedDispatchStaging then
    fe.clearSanctionedDispatchStaging()
  end
  runtime.dispatchUiActive = false
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_reschedule")
  return true, nil
end

function M.onRaceBegin(raceName)
  srTrace(string.format("onRaceBegin enter sessionRaceName=%s", tostring(raceName)))
  if not isSanctionedRaceNameConfigured(raceName) then
    srTrace("onRaceBegin bail: session raceName not in level sanctionedRaceNames (cfg whitelist)")
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer or (offer.phase ~= "committed" and offer.phase ~= "racing") then
    srTrace(string.format(
      "onRaceBegin bail: no offer or bad phase (phase=%s)",
      offer and tostring(offer.phase) or "nil"
    ))
    return
  end
  if offer.raceName ~= raceName then
    srTrace(string.format(
      "onRaceBegin bail: offer.raceName mismatch (offer.raceName=%s session=%s) — circuit uses id \"track\" for beginFreeroamRace",
      tostring(offer.raceName),
      tostring(raceName)
    ))
    return
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  -- Prefer the staging gate when present, but do not require it for a committed racing-team business offer.
  local gateActive = ctf and ctf.isTrackGridCareerStagingGateActive and ctf.isTrackGridCareerStagingGateActive()
  if not gateActive and offer.racingTeamBusinessOffer ~= true then
    srTrace(string.format(
      "onRaceBegin bail: staging gate inactive and not racingTeamBusinessOffer (gateActive=%s teamOffer=%s)",
      tostring(gateActive == true),
      tostring(offer.racingTeamBusinessOffer == true)
    ))
    return
  end
  if offer.racingTeamBusinessOffer == true and career_modules_competitiveRace_aiRacers
      and career_modules_competitiveRace_aiRacers.getLastSpawnedLineupSnapshot then
    offer.rematchAiLineupSnapshot = career_modules_competitiveRace_aiRacers.getLastSpawnedLineupSnapshot()
  end
  offer.phase = "racing"
  sr.nextGenAt = 0
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(gameplay_events_freContracts_state.getSimTime())
  runtime.dispatchUiActive = false
  runtime.suppressFrePayouts = true
  -- Class cap / podium: trusted live hp/kg vs bracket max with 5% scrutineering tolerance.
  local pwMax = tonumber(offer.classPwMax)
  local pwLive = nil
  if career_modules_competitiveRace_aiRacers and career_modules_competitiveRace_aiRacers.getPlayerVehiclePwForPodiumCapCheck then
    pwLive = career_modules_competitiveRace_aiRacers.getPlayerVehiclePwForPodiumCapCheck()
  end
  local isOver = (pwMax and pwMax > 0 and type(pwLive) == "number" and pwLive > (pwMax * 1.05))
  runtime.podiumEligible = {
    result = not isOver,
    pwLive = pwLive,
    pwMax = pwMax,
    fine = 350,
  }
  srTrace(string.format(
    "onRaceBegin ARMED suppressFrePayouts=true podiumEligible=%s offerId=%s classPwMax=%s pwLive=%s",
    tostring(runtime.podiumEligible.result == true),
    tostring(offer.id),
    tostring(offer.classPwMax),
    tostring(pwLive or "n/a")
  ))
end

local function notifyBusinessRematchOutcome(offer, place, reason)
  if type(offer) ~= "table" or offer.racingTeamBusinessOffer ~= true then
    return
  end
  local rt = rawget(_G, "career_modules_business_racingTeam")
  if rt and rt.onBusinessSanctionedRaceOutcome then
    rt.onBusinessSanctionedRaceOutcome(offer, place, reason)
  end
end

function M.shouldSuppressFrePayouts()
  if runtime.suppressFrePayouts == true then
    return true
  end
  local ctf = gameplay_events_freeroam_competitiveTrackFlow
  if ctf then
    if ctf.isRacingTeamProxyRaceActive and ctf.isRacingTeamProxyRaceActive() then
      return true
    end
    if ctf.isRacingTeamProxyRaceSessionActive and ctf.isRacingTeamProxyRaceSessionActive() then
      return true
    end
  end
  return false
end

function M.isPodiumEligible()
  return runtime.podiumEligible and runtime.podiumEligible.result == true
end

function M.clearRuntime()
  srTrace("clearRuntime() resetting suppressFrePayouts / podiumEligible / dispatchUiActive")
  runtime.suppressFrePayouts = false
  runtime.podiumEligible = { result = false }
  runtime.dispatchUiActive = false
end

local function payPodium(place)
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local offer = sr.offer
  if not offer then
    return
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
  local xpNum = tonumber(xpStored)
  local xpAmount = (xpNum ~= nil) and math.max(0, math.floor(xpNum)) or moneyToSanctionedXp(amount)
  if amount <= 0 then
    mCelebrationRewards = { money = 0, noRewardDetail = "No payout configured for this podium position." }
    M.finishOfferClear()
    return
  end
  local rewardData = {
    money = { amount = amount, canBeNegative = false }
  }
  local skillKey = freConfig.getSkillKey(DISCIPLINE_ROAD)
  local grantedXp = 0
  if skillKey and xpAmount > 0 then
    rewardData[skillKey] = { amount = xpAmount }
    grantedXp = xpAmount
  end
  local useBusinessPayout = type(offer) == "table" and offer.racingTeamBusinessOffer == true and offer.businessId ~= nil
  local businessId = useBusinessPayout and (tonumber(offer.businessId) or offer.businessId) or nil

  if useBusinessPayout and businessId and career_modules_bank and career_modules_bank.getBusinessAccount and career_modules_bank.rewardToAccount then
    local businessAccount = career_modules_bank.getBusinessAccount("racingTeam", businessId)
    local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
    if accountId then
      -- League-2+ "player races alongside proxy" deposits only a fraction of
      -- the gross podium payout. League 1 player races keep their full gross.
      -- Proxy/AI races still apply their own driver-cut on full gross via
      -- racingTeam.settleProxySanctionedRaceFromAiResults. The multiplier
      -- lives in racingTeamRuntimeState K so QA can dial it during beta.
      local isOwnerDriver = offer.playerProxyAlongsideRace == true
      local playerCut = 1.0
      if isOwnerDriver then
        local rtState = rawget(_G, "career_modules_business_racingTeamRuntimeState")
        playerCut = (rtState and rtState.K and tonumber(rtState.K.RACING_TEAM_PLAYER_RACE_PAYOUT_MULTIPLIER)) or 0.85
      end

      local playerAmount = math.floor(amount * playerCut)
      local crewShare = math.floor(amount - playerAmount)
      local netPct = math.floor(playerCut * 100 + 0.5)
      local crewPct = 100 - netPct
      local txLabel = string.format("Sanctioned team race - P%d", place)
      local txDesc = isOwnerDriver 
        and string.format("Circuit payout: +$%d (%d%% net), -$%d (%d%% crew share)", playerAmount, netPct, crewShare, crewPct)
        or string.format("Circuit payout: +$%d (100%% net)", playerAmount)

      local ok = career_modules_bank.rewardToAccount({
        money = { amount = playerAmount, canBeNegative = false },
      }, accountId, txLabel, txDesc)
      if ok then
        local uiMessage = isOwnerDriver
          and string.format("P%d Finish: +$%d (%d%% net, %d%% crew share).", place, playerAmount, netPct, crewPct)
          or string.format("P%d Finish: +$%d (100%% net).", place, playerAmount)
        if ui_message then ui_message(uiMessage, 7, "Racing Team", "info") end
        local rt = rawget(_G, "career_modules_business_racingTeam")
        if grantedXp > 0 then
          if rt and rt.addBusinessXP then
            rt.addBusinessXP(businessId, grantedXp)
          end
        end
        mCelebrationRewards = { money = playerAmount, disciplineXp = grantedXp }
        if skillKey and grantedXp > 0 and career_modules_payment and career_modules_payment.reward then
          career_modules_payment.reward({
            [skillKey] = { amount = grantedXp },
          }, {
            label = string.format("Sanctioned race - P%d", place),
            tags = { "gameplay", "reward", "fre", "sanctioned_race" },
          }, true)
        end
      else
        useBusinessPayout = false
      end
    else
      useBusinessPayout = false
    end
  end
  
  if not useBusinessPayout or not businessId then
    if not career_modules_payment or not career_modules_payment.reward then
      mCelebrationRewards = { money = 0, noRewardDetail = "No payout configured for this podium position." }
      M.finishOfferClear()
      return
    end
    mCelebrationRewards = { money = math.floor(amount), disciplineXp = grantedXp }
    career_modules_payment.reward(rewardData, {
      label = string.format("Sanctioned race - P%d", place),
      tags = { "gameplay", "reward", "fre", "sanctioned_race" },
    }, true)
  end

  M.finishOfferClear()
end

function M.finishOfferClear()
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  sr.offer = nil
  local now = state.simTime or 0
  local cfg = loadCfg()
  sr.nextGenAt = now + math.max(0.5, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
  M.clearRuntime()
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
  career_saveSystem.saveCurrent()
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_race_end")
end

function M.settleFromAiResults(aiResults, raceName)
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  srTrace(string.format(
    "settleFromAiResults enter raceName=%s suppressFrePayouts=%s podiumEligible=%s offer=%s teamOffer=%s businessId=%s league1PlayerRace=%s phase=%s",
    tostring(raceName),
    tostring(runtime.suppressFrePayouts == true),
    tostring(runtime.podiumEligible and runtime.podiumEligible.result == true),
    tostring(o ~= nil),
    tostring(o and o.racingTeamBusinessOffer == true),
    tostring(o and o.businessId),
    tostring(o and o.league1PlayerRace == true),
    tostring(o and o.phase)
  ))
  if not runtime.suppressFrePayouts then
    local rn = raceName or (o and o.raceName)
    if rn and isSanctionedRaceNameConfigured(rn) and o and type(o.raceName) == "string" and o.raceName == rn
        and (o.phase == "committed" or o.phase == "racing") then
      -- Always clear: a team/league1 offer that reached race end without arming HUD is dead weight;
      -- keeping it would block every subsequent commitAndNavigateExternalOffer ("already committed").
      M.finishOfferClear()
    end
    return
  end
  mCelebrationRewards = nil
  local function armFleetIfTeamOffer(offer)
    if not offer then
      return
    end
    local rt = rawget(_G, "career_modules_business_racingTeam")
    if rt and rt.armFleetVehicleCooldownAfterSanctionedRaceSettled then
      rt.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
    end
  end
  if not aiResults then
    notifyBusinessRematchOutcome(o, nil, "no_results")
    mCelebrationRewards = { money = 0, noRewardDetail = "No race results — no podium reward." }
    armFleetIfTeamOffer(o)
    M.finishOfferClear()
    return
  end
  local place = nil
  for _, row in ipairs(aiResults) do
    if row.isPlayer then
      place = tonumber(row.place)
      break
    end
  end
  if not place then
    notifyBusinessRematchOutcome(o, nil, "no_place")
    mCelebrationRewards = { money = 0, noRewardDetail = "Couldn't determine placement — no podium reward." }
    armFleetIfTeamOffer(o)
    M.finishOfferClear()
    return
  end
  if place ~= 1 then
    notifyBusinessRematchOutcome(o, place, "non_win")
  else
    notifyBusinessRematchOutcome(o, place, "win")
  end
  armFleetIfTeamOffer(o)
  if place > 3 then
    mCelebrationRewards = { money = 0, noRewardDetail = "Didn't place on the podium — no podium rewards." }
    M.finishOfferClear()
    return
  end

  if runtime.podiumEligible and runtime.podiumEligible.result then
    local rtMod = rawget(_G, "career_modules_business_racingTeam")
    srTrace(string.format(
      "settleFromAiResults CALLING notifyOfficialSanctionedPodium place=%d rtMod=%s fn=%s",
      place,
      tostring(rtMod ~= nil),
      tostring(rtMod and rtMod.notifyOfficialSanctionedPodium ~= nil)
    ))
    if rtMod and rtMod.notifyOfficialSanctionedPodium then
      rtMod.notifyOfficialSanctionedPodium(place, o)
    end
    payPodium(place)
    return
  end

  srTrace(string.format("settleFromAiResults SKIP podium place=%d podiumEligible=false", place))
  local inf = runtime.podiumEligible or {}
  local fine = inf.fine or 350
  local pwLive = inf.pwLive or 0
  local pwMax = inf.pwMax or 0
  local isTeamOffer = type(o) == "table" and o.racingTeamBusinessOffer == true and o.businessId ~= nil
  local fineCharged = false
  if isTeamOffer and career_modules_bank then
    local bAccount = career_modules_bank.getBusinessAccount("racingTeam", o.businessId)
    local accountId = bAccount and (bAccount.id or bAccount.accountId)
    if accountId then
      local dqMsg = string.format("Technical DQ (%.3f hp/kg > %.3f hp/kg limit)", pwLive, pwMax)
      fineCharged = career_modules_bank.removeFunds(accountId, fine, "Parc Ferme Fine", dqMsg, true) == true
    end
  end
  local detail = string.format("Technical Disqualification: Power-to-weight (%.3f hp/kg) exceeded class limit (%.3f hp/kg). Podium purse withheld.", pwLive, pwMax)
  if fineCharged then detail = detail .. string.format(" $%d fine deducted from team funds.", fine) end
  
  mCelebrationRewards = { money = 0, noRewardDetail = detail }
  if ui_message then ui_message(detail, 8, "Parc Ferme", "error") end
  M.finishOfferClear()
end

function M.onRaceAborted()
  mCelebrationRewards = nil
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o and not runtime.suppressFrePayouts then
    return
  end
  if o then
    notifyBusinessRematchOutcome(o, nil, "aborted")
  end
  -- Also clear on abort of a committed offer (not just racing/suppressed): leaving it in place
  -- means commitAndNavigateExternalOffer rejects every next accept with "already committed".
  if runtime.suppressFrePayouts or (o and (o.phase == "racing" or o.phase == "committed")) then
    M.finishOfferClear()
  end
end

--- A "committed" or "racing" sanctioned offer persisted in freContractsSponsors.json represents a
--- race the player started in a previous session (save written by commitAndNavigateExternalOffer or
--- onRaceBegin). After a fresh load `runtime` is reset (no active scenario, no HUD suppression), so
--- the offer has no live race behind it — but the commit guard in commitAndNavigateExternalOffer
--- rejects every future accept with "A sanctioned race is already committed." until the offer is
--- cleared. Evict it on career activation so the player can accept again.
function M.evictStaleOfferOnCareerLoad()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o then
    return
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return
  end
  srTrace(string.format(
    "evictStaleOfferOnCareerLoad clearing phase=%s id=%s teamOffer=%s league1=%s",
    tostring(o.phase),
    tostring(o.id),
    tostring(o.racingTeamBusinessOffer == true),
    tostring(o.league1PlayerRace == true)))
  sr.offer = nil
  local now = state.simTime or 0
  local cfg = loadCfg()
  sr.nextGenAt = now + math.max(0.5, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
  M.clearRuntime()
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
  career_saveSystem.saveCurrent()
  gameplay_events_freContracts_ui.emitUiStateUpdate("sanctioned_evict_stale_on_load")
end

function M.onCareerTrackStagingExitAbandoned()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if o and type(o.raceName) == "string" and isSanctionedRaceNameConfigured(o.raceName) then
    notifyBusinessRematchOutcome(o, nil, "staging_exit")
    M.finishOfferClear()
  end
end

function M.getRematchAiLineupSnapshot()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or o.phase ~= "committed" then
    return nil
  end
  if o.racingTeamBusinessOffer ~= true then
    return nil
  end
  if type(o.rematchAiLineupSnapshot) ~= "table" or #o.rematchAiLineupSnapshot == 0 then
    return nil
  end
  return o.rematchAiLineupSnapshot
end

function M.isRacingUnlocked(disciplineId)
  if string.lower(tostring(disciplineId or "")) ~= DISCIPLINE_ROAD then
    return false
  end
  return skillOk(DISCIPLINE_ROAD)
end

function M.isSanctionedCircuitRaceActive()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  return o and o.phase == "racing" and type(o.raceName) == "string" and isSanctionedRaceNameConfigured(o.raceName)
end

function M.isSanctionedCircuitRaceUseAltRoute()
  if not M.isSanctionedCircuitRaceActive() then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o then
    return false
  end
  return string.lower(tostring(o.raceRouteType or "main")) == "alt"
end

function M.getAiPoolReferencePw()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return nil
  end
  local hi = tonumber(o.classPwMax)
  if not hi or hi <= 0 then
    return nil
  end
  return hi
end

M.getAiPoolReferenceHp = M.getAiPoolReferencePw

function M.getAiPoolReferencePwMin()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return nil
  end
  local lo = tonumber(o.classPwMin)
  if not lo or lo <= 0 then
    return nil
  end
  return lo
end

M.getAiPoolReferenceHpMin = M.getAiPoolReferencePwMin

-- For AI spawn when player hp/kg cannot be read: bracket limits (hp/kg) + branch.
function M.getAiSpawnSanctionedContext()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return nil
  end
  local lo = tonumber(o.classPwMin)
  local hi = tonumber(o.classPwMax)
  if not hi or hi <= 0 then
    return nil
  end
  if not lo or lo < 0 then
    lo = 0
  end
  local branch = o.hpBracketBranch
  if type(branch) ~= "string" or branch == "" then
    branch = nil
  end
  return {
    classPwMin = lo,
    classPwMax = hi,
    hpBracketBranch = branch,
    racingTeamBusinessOffer = o.racingTeamBusinessOffer == true,
  }
end

function M.getSanctionedOfferLapCount()
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" and o.phase ~= "available" then
    return nil
  end
  local n = tonumber(o.lapCount)
  if n and n > 0 then
    return math.floor(n)
  end
  return nil
end

--- Like getSanctionedOfferLapCount but only committed/racing and optional race id match (in-race HUD when suppression not yet armed).
function M.getCommittedRacingSanctionedOfferLapCount(raceName)
  if not gameplay_events_freContracts_state.isCareerActive() then
    return nil
  end
  local state = gameplay_events_freContracts_state.getState()
  local sr = ensureSrState(state)
  local o = sr.offer
  if not o or type(o.raceName) ~= "string" or not isSanctionedRaceNameConfigured(o.raceName) then
    return nil
  end
  if o.phase ~= "committed" and o.phase ~= "racing" then
    return nil
  end
  if type(raceName) == "string" and raceName ~= "" and o.raceName ~= raceName then
    return nil
  end
  local n = tonumber(o.lapCount)
  if n and n > 0 then
    return math.floor(n)
  end
  return nil
end

M.loadCfg = loadCfg
M.loadCfgForLevel = loadCfgForLevel
M.isSanctionedRaceNameConfigured = isSanctionedRaceNameConfigured

--- Highest classPwMax among Stock-branch hp/kg brackets.
function M.getStockClassPwCeiling()
  local maxStock = nil
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    if string.lower(tostring(b.branch or "")) == "stock" then
      local m = tonumber(b.classPwMax)
      if m and m > 0 and (not maxStock or m > maxStock) then
        maxStock = m
      end
    end
  end
  return maxStock or 0.2822
end

M.getStockClassHpCeiling = M.getStockClassPwCeiling

--- Branch from player/fleet hp/kg (power ÷ weight in kg).
function M.getSanctionedBranchForPw(pw)
  local p = tonumber(pw)
  if not p or p <= 0 then
    return "stock"
  end
  local bestBranch = "stock"
  local bestRank = 0
  local rank = { stock = 1, modified = 2, super = 3, open = 4 }
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    local lo = tonumber(b.classPwMin) or 0
    local hi = tonumber(b.classPwMax) or 0
    if p >= lo and p <= hi then
      local br = string.lower(tostring(b.branch or ""))
      local r = rank[br] or 0
      if r > bestRank then
        bestRank = r
        bestBranch = br ~= "" and br or "stock"
      end
    end
  end
  return bestBranch
end

M.getSanctionedBranchForHp = M.getSanctionedBranchForPw

--- Sub-bracket display label for fleet/staging: pw in [classPwMin, classPwMax]. On overlap, pick bracket with highest classPwMin.
function M.getSanctionedPwBracketLabelForPw(pw)
  local p = tonumber(pw)
  if not p or p <= 0 then
    return nil
  end
  local bestLabel = nil
  local bestLo = -1e9
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    local lo = tonumber(b.classPwMin) or 0
    local hi = tonumber(b.classPwMax) or 0
    if p >= lo and p <= hi then
      if lo > bestLo then
        bestLo = lo
        bestLabel = b.label
      end
    end
  end
  return bestLabel
end

function M.getSanctionedPwBracketById(bracketId)
  if type(bracketId) ~= "string" or bracketId == "" then
    return nil
  end
  local want = string.lower(bracketId)
  for _, b in ipairs(DEFAULT_SANCTIONED_PW_BRACKETS) do
    if string.lower(tostring(b.id or "")) == want then
      return {
        branch = b.branch,
        id = b.id,
        label = b.label,
        classPwMin = tonumber(b.classPwMin) or 0,
        classPwMax = tonumber(b.classPwMax) or 0,
      }
    end
  end
  return nil
end

M.getSanctionedHpBracketById = M.getSanctionedPwBracketById

function M.consumeSanctionedCelebrationRewards()
  local r = mCelebrationRewards
  mCelebrationRewards = nil
  return r
end

function M.getOfferGenerationPeriodMinutes()
  local cfg = loadCfg()
  if not cfg or type(cfg.variants) ~= "table" or #cfg.variants == 0 then
    return nil
  end
  return math.max(0.25, tonumber(cfg.defaultOfferRefreshMinutes) or 12)
end

return M
