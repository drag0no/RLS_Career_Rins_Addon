-- Opportunity economy: living job market (jobs only).
--
-- Surges are demand episodes, not per-payout pressure. About MIN_HOT_JOBS leaves
-- stay in high demand. Each episode lasts ~1–3 career sim-days if left alone
-- (NPCs fulfill demand on the clock). Player completions nibble that pool, so
-- hammering a hot job burns it down faster; 1–2 jobs should barely dent it.
-- Neglect a surge and NPCs may finish it without you.
--
-- Freeroam / racing is intentionally excluded — FRE Contracts owns that.
--
-- Design guarantees:
--   * Purely multiplicative; idle baseline stays at 1.0.
--   * Never writes career_economyAdjuster.typeMultipliers (difficulty/challenges).
--   * Suspended entirely while a challenge is active.
--   * Disabled (0) activities are never revived or surged.
--   * Always keeps a minimum number of "hot" jobs when possible.

local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'career_economyAdjuster' }

local SAVE_VERSION = 3
local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/activityHeat.json"

-- Career sim-day (same clock as globalEconomy — not map TOD).
local SIM_SECONDS_PER_GAME_DAY = 1200

-- Tunables
local TRANSIENT_FLOOR     = 0.50
local TRANSIENT_CEIL      = 2.00
local MIN_HOT_JOBS        = 3
local HOT_THRESHOLD       = 1.10    -- +10% — Market Watch "high demand"
local SURGE_DAYS_MIN      = 1.0
local SURGE_DAYS_MAX      = 3.0
local SURGE_FACTOR_MIN    = 1.12    -- +12%
local SURGE_FACTOR_MAX    = 1.40    -- +40%
local COOLDOWN_DAYS_MIN   = 0.45
local COOLDOWN_DAYS_MAX   = 1.25
local PLAYER_NIBBLE       = 1.0     -- one completion = one job of demand
local PLAYER_NIBBLE_DEBOUNCE_SEC = 2.0 -- collapse multi addAttributes on one job
local NPC_RATE_JITTER     = 0.22    -- ±% on NPC jobs/day when a surge starts

-- Notification: only when a job newly enters high demand (no cooling spam)
local NOTIF_PREF_KEY = "jobMarket"
local ADVERT_COOLDOWN_SEC = 180 -- Indeed-style marker ads, real-time seconds

-- Branch / leaf taxonomy (skill-tree aligned + Gig Work umbrella)
local BRANCHES = {
  {
    id = "civilService",
    label = "Civil Service",
    leaves = {
      { id = "police", label = "Police" },
      { id = "bus", label = "Bus" },
      { id = "ambulance", label = "Paramedic" },
    },
  },
  {
    id = "logistics",
    label = "Logistics",
    leaves = {
      { id = "delivery_parcel", label = "Parcels" },
      { id = "delivery_vehicle", label = "Car Jockeys" },
      { id = "delivery_trailer", label = "Trailers" },
      { id = "delivery_fluid", label = "Fluids" },
      { id = "delivery_dryBulk", label = "Dry Bulk" },
      { id = "delivery_cement", label = "Cement" },
      { id = "delivery_cash", label = "Cash Runs" },
      { id = "facilityWork", label = "Facility Work" },
    },
  },
  {
    id = "gigWork",
    label = "Gig Work",
    leaves = {
      { id = "taxi", label = "Taxi" },
      { id = "repo", label = "Repo" },
      { id = "beamEats", label = "BeamEats" },
    },
  },
}

-- NPC jobs fulfilled per sim-day while a leaf is surged (idle duration ≈ pool / rate).
-- Higher = busier market = bigger pool and faster miss-out if you ignore it.
local NPC_JOBS_PER_DAY = {
  police = 3.5,
  bus = 4.0,
  ambulance = 3.0,
  delivery_parcel = 8.0,
  delivery_vehicle = 4.5,
  delivery_trailer = 4.0,
  delivery_fluid = 3.0,
  delivery_dryBulk = 3.0,
  delivery_cement = 2.5,
  delivery_cash = 2.5,
  facilityWork = 3.5,
  taxi = 8.0,
  repo = 4.0,
  beamEats = 5.0,
}

local JOB_LEAF_SET = {}
local LEAF_LABEL = {}
for _, branch in ipairs(BRANCHES) do
  for _, leaf in ipairs(branch.leaves) do
    JOB_LEAF_SET[leaf.id] = true
    LEAF_LABEL[leaf.id] = leaf.label
  end
end

-- ── Runtime state ──

-- episodes[leafId] = { factor, pool, poolMax, npcRate, durationDays, startedAtSim }
local episodes = {}
-- cooldownUntil[leafId] = simTime when the leaf may surge again
local cooldownUntil = {}
local debugForce = {}
local bandNotified = {}
local lastAdvertAt = 0
local lastAdvertJob = nil
local lastPayoutNotifAt = 0
local PAYOUT_NOTIF_COOLDOWN_SEC = 45
local lastPlayerNibbleAt = {} -- [leafId] = os.clock()

local simTime = 0
local tickCount = 0
local lastTickJob = nil
local loaded = false
local suspendedForChallenge = false
local pendingTransientPush = false
local suppressDemandNotifs = false
local marketDirty = false

-- ── Helpers ──

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function randomInRange(lo, hi)
  return lo + math.random() * (hi - lo)
end

local function shuffleInPlace(list)
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

local function careerActive()
  return career_career and career_career.isActive()
end

local function isChallengeActive()
  return career_challengeModes and career_challengeModes.isChallengeActive and career_challengeModes.isChallengeActive() == true
end

local function notificationsEnabled()
  if not ui_phone_layout then
    if extensions and extensions.load then pcall(extensions.load, "ui_phone_layout") end
  end
  if ui_phone_layout and ui_phone_layout.getSettings then
    local ok, s = pcall(ui_phone_layout.getSettings)
    if ok and type(s) == "table" and type(s.notifications) == "table" then
      return s.notifications[NOTIF_PREF_KEY] ~= false
    end
  end
  return true
end

-- Normalize reason.tags (array or lookup dict) into a lookup dict.
local function tagsAsLookup(tags)
  if type(tags) ~= "table" then return {} end
  local out = {}
  local hasStringKeys = false
  for k, v in pairs(tags) do
    if type(k) == "number" and type(v) == "string" then
      out[v] = true
    elseif type(k) == "string" and v == true then
      out[k] = true
      hasStringKeys = true
    elseif type(k) == "string" and v then
      out[k] = true
      hasStringKeys = true
    end
  end
  if hasStringKeys and next(out) then return out end
  if next(out) then return out end
  return tags
end

-- Map payout tags -> job leaf id (nil = ignore: racing/FRE/criminal/unknown).
local function classifyEarningTags(tags)
  tags = tagsAsLookup(tags)
  local function has(t) return tags[t] == true end

  if has("criminal") then return nil end
  if has("race") or has("demo") or has("sanctioned_race") or has("drag") then return nil end
  if has("fre") or has("freContract") or has("fre_contract") then return nil end

  if has("taxi") then return "taxi" end
  if has("beamEats") or has("beameats") then return "beamEats" end
  if has("repo") then return "repo" end
  if has("bus") then return "bus" end
  if has("ambulance") or has("paramedic") then return "ambulance" end
  if has("facilityWork") then return "facilityWork" end
  if has("police") or has("arrest") then return "police" end

  if has("delivery_vehicle") or has("vehicleDelivery") then return "delivery_vehicle" end
  if has("delivery_trailer") then return "delivery_trailer" end
  if has("delivery_fluid") then return "delivery_fluid" end
  if has("delivery_dryBulk") then return "delivery_dryBulk" end
  if has("delivery_cement") then return "delivery_cement" end
  if has("delivery_cash") then return "delivery_cash" end
  if has("delivery_parcel") then return "delivery_parcel" end
  if has("deliveryReward") then return "delivery_parcel" end

  return nil
end

local function isTypeEnabled(typeName)
  if not career_economyAdjuster or not career_economyAdjuster.getTypeMultiplier then return true end
  return (career_economyAdjuster.getTypeMultiplier(typeName) or 1.0) ~= 0
end

local function isLeafAvailable(leafId)
  if not JOB_LEAF_SET[leafId] then return false end
  if leafId == "taxi" then return gameplay_taxi ~= nil or gameplay_rlsTaxi ~= nil end
  if leafId == "beamEats" then return gameplay_beamEats ~= nil end
  if leafId == "repo" then return gameplay_repo ~= nil end
  if leafId == "bus" then return gameplay_bus ~= nil end
  if leafId == "ambulance" then return gameplay_ambulance ~= nil end
  if leafId == "facilityWork" then return gameplay_facilityWork ~= nil end
  if leafId == "police" then return career_modules_enforcement ~= nil or gameplay_police ~= nil end
  if leafId:find("^delivery_") then
    return (gameplay_loading or career_modules_delivery_general) ~= nil
  end
  return true
end

local function isLeafUsable(leafId)
  if not isLeafAvailable(leafId) then return false end
  if not isTypeEnabled(leafId) then
    if leafId == "taxi" then
      if career_economyAdjuster and career_economyAdjuster.getAvailableTypes then
        for _, t in ipairs(career_economyAdjuster.getAvailableTypes() or {}) do
          if (t == "taxi" or tostring(t):find("^taxi_")) and isTypeEnabled(t) then
            return true
          end
        end
      end
    end
    return false
  end
  return true
end

local function listUsableLeaves()
  local out = {}
  for _, branch in ipairs(BRANCHES) do
    for _, leaf in ipairs(branch.leaves) do
      if isLeafUsable(leaf.id) then
        out[#out + 1] = leaf.id
      end
    end
  end
  return out
end

local function remainingFrac(ep)
  if not ep then return 0 end
  local maxPool = tonumber(ep.poolMax) or 0
  if maxPool <= 1e-6 then return 0 end
  return clamp((tonumber(ep.pool) or 0) / maxPool, 0, 1)
end

local function effectiveMult(leafId)
  if debugForce[leafId] then
    return clamp(tonumber(debugForce[leafId]) or 1.0, TRANSIENT_FLOOR, TRANSIENT_CEIL)
  end
  local ep = episodes[leafId]
  if ep and (tonumber(ep.pool) or 0) > 1e-6 then
    return clamp(tonumber(ep.factor) or 1.0, TRANSIENT_FLOOR, TRANSIENT_CEIL)
  end
  return 1.0
end

local function snapshotMults(leaves)
  local snap = {}
  for _, id in ipairs(leaves) do
    snap[id] = effectiveMult(id)
  end
  return snap
end

local function fireHighDemandNotification(leafId, magnitude)
  if not notificationsEnabled() then return end
  local label = LEAF_LABEL[leafId] or leafId
  local pct = math.floor(math.abs(magnitude - 1.0) * 100 + 0.5)
  if not (guihooks and guihooks.trigger) then return end
  pcall(guihooks.trigger, "PhoneLockNotification", {
    title = string.format("%s in high demand", label),
    message = string.format("%s is paying a premium right now.", label),
    meta = string.format("+%d%% pay", pct),
    kind = "success",
    source = "Market Watch",
    category = NOTIF_PREF_KEY,
    ttl = 10,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
end

local function maybeShowOpportunityAdvert(source)
  if not careerActive() or not loaded then return false end
  if isChallengeActive() then return false end
  if not notificationsEnabled() then return false end

  local now = os.time()
  if lastAdvertAt > 0 and (now - lastAdvertAt) < ADVERT_COOLDOWN_SEC then
    return false
  end

  local hot = {}
  for _, id in ipairs(listUsableLeaves()) do
    local m = effectiveMult(id)
    if m >= HOT_THRESHOLD then
      hot[#hot + 1] = { id = id, m = m }
    end
  end
  if #hot == 0 then return false end
  table.sort(hot, function(a, b) return a.m > b.m end)

  local pick = hot[1]
  if #hot > 1 and lastAdvertJob then
    for _, h in ipairs(hot) do
      if h.id ~= lastAdvertJob then
        pick = h
        break
      end
    end
  end

  lastAdvertAt = now
  lastAdvertJob = pick.id
  local label = LEAF_LABEL[pick.id] or pick.id
  local pct = math.floor((pick.m - 1.0) * 100 + 0.5)
  if not (guihooks and guihooks.trigger) then return false end
  pcall(guihooks.trigger, "PhoneLockNotification", {
    title = string.format("Hiring: %s", label),
    message = string.format("%s rates are up — open Market Watch → Opportunities.", label),
    meta = string.format("+%d%%", pct),
    kind = "info",
    source = "Market Watch",
    category = NOTIF_PREF_KEY,
    ttl = 8,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
  return true
end

local function checkBandCrossings(leafId, oldMult, newMult)
  bandNotified[leafId] = bandNotified[leafId] or {}
  local flags = bandNotified[leafId]

  if oldMult < HOT_THRESHOLD and newMult >= HOT_THRESHOLD then
    if not flags.hot then
      flags.hot = true
      if not suppressDemandNotifs then
        fireHighDemandNotification(leafId, newMult)
      end
    end
  elseif newMult < HOT_THRESHOLD then
    flags.hot = nil
  end
end

local function rebakeDeliveryOffersIfNeeded(before, after)
  local changed = {}
  local any = false
  for id, newM in pairs(after or {}) do
    if type(id) == "string" and id:find("^delivery_") then
      local oldM = (before and before[id]) or newM
      if math.abs((tonumber(oldM) or 1) - (tonumber(newM) or 1)) > 1e-4 then
        changed[id] = newM
        any = true
      end
    end
  end
  if not any then return end
  if career_modules_delivery_generator and career_modules_delivery_generator.rebakeOpenOffersEconomy then
    pcall(career_modules_delivery_generator.rebakeOpenOffersEconomy, changed)
  end
end

local function syncAllDeliveryOffersToMarket()
  local usable = listUsableLeaves()
  local mults = {}
  local any = false
  for _, id in ipairs(usable) do
    if id:find("^delivery_") then
      mults[id] = effectiveMult(id)
      any = true
    end
  end
  if not any then return end
  if career_modules_delivery_generator and career_modules_delivery_generator.rebakeOpenOffersEconomy then
    pcall(career_modules_delivery_generator.rebakeOpenOffersEconomy, mults)
  end
end

local function pushTransients(usable)
  if not career_economyAdjuster or not career_economyAdjuster.setTransientMultiplier then return end
  usable = usable or listUsableLeaves()
  career_economyAdjuster.clearTransientMultipliers()

  local usableSet = {}
  for _, id in ipairs(usable) do usableSet[id] = true end

  for leafId, _ in pairs(JOB_LEAF_SET) do
    if usableSet[leafId] then
      local factor = effectiveMult(leafId)
      if math.abs(factor - 1.0) > 1e-6 then
        career_economyAdjuster.setTransientMultiplier(leafId, factor)
        if leafId == "taxi" and career_economyAdjuster.getAvailableTypes then
          for _, t in ipairs(career_economyAdjuster.getAvailableTypes() or {}) do
            if tostring(t):find("^taxi_") then
              career_economyAdjuster.setTransientMultiplier(t, factor)
            end
          end
        end
      end
    end
  end
end

local function countHot(usable)
  local n = 0
  for _, id in ipairs(usable) do
    if effectiveMult(id) >= HOT_THRESHOLD then
      n = n + 1
    end
  end
  return n
end

local function endSurge(leafId, reason)
  local ep = episodes[leafId]
  if not ep then return end
  episodes[leafId] = nil
  local cdDays = randomInRange(COOLDOWN_DAYS_MIN, COOLDOWN_DAYS_MAX)
  cooldownUntil[leafId] = simTime + cdDays * SIM_SECONDS_PER_GAME_DAY
  bandNotified[leafId] = bandNotified[leafId] or {}
  bandNotified[leafId].hot = nil
  marketDirty = true
  log("I", "activityHeat", string.format("Surge ended: %s (%s) remaining=%.2f",
    tostring(leafId), tostring(reason or "empty"), tonumber(ep.pool) or 0))
end

local function startSurge(leafId, opts)
  if not leafId or not JOB_LEAF_SET[leafId] then return false end
  if not isLeafUsable(leafId) then return false end
  opts = opts or {}

  local durationDays = tonumber(opts.durationDays) or randomInRange(SURGE_DAYS_MIN, SURGE_DAYS_MAX)
  durationDays = clamp(durationDays, SURGE_DAYS_MIN, SURGE_DAYS_MAX)
  local factor = tonumber(opts.factor) or randomInRange(SURGE_FACTOR_MIN, SURGE_FACTOR_MAX)
  factor = clamp(factor, HOT_THRESHOLD, TRANSIENT_CEIL)

  local baseRate = NPC_JOBS_PER_DAY[leafId] or 4.0
  local jitter = 1.0 + randomInRange(-NPC_RATE_JITTER, NPC_RATE_JITTER)
  local npcRate = math.max(1.2, baseRate * jitter)
  if opts.npcRate then npcRate = math.max(0.5, tonumber(opts.npcRate) or npcRate) end

  local pool = npcRate * durationDays
  if opts.pool then pool = math.max(1.0, tonumber(opts.pool) or pool) end

  episodes[leafId] = {
    factor = factor,
    pool = pool,
    poolMax = pool,
    npcRate = npcRate,
    durationDays = durationDays,
    startedAtSim = simTime,
  }
  cooldownUntil[leafId] = nil
  marketDirty = true
  return true
end

local function pickSurgeCandidates(usable, includeCooldown)
  local out = {}
  for _, id in ipairs(usable) do
    if not episodes[id] and not debugForce[id] then
      local cd = cooldownUntil[id]
      local onCooldown = cd and simTime < cd
      if includeCooldown or not onCooldown then
        out[#out + 1] = id
      end
    end
  end
  return shuffleInPlace(out)
end

local function ensureCoverage(usable)
  usable = usable or listUsableLeaves()
  local need = MIN_HOT_JOBS - countHot(usable)
  if need <= 0 then return end

  local candidates = pickSurgeCandidates(usable, false)
  if #candidates < need then
    -- Last resort: allow jobs still on cooldown so we keep 3 options.
    candidates = pickSurgeCandidates(usable, true)
  end

  for i = 1, math.min(need, #candidates) do
    startSurge(candidates[i])
  end
end

local function applyMarketChanges(before)
  local usable = listUsableLeaves()
  ensureCoverage(usable)
  pushTransients(usable)
  local after = snapshotMults(usable)
  for _, id in ipairs(usable) do
    checkBandCrossings(id, (before and before[id]) or 1.0, after[id] or 1.0)
  end
  pcall(rebakeDeliveryOffersIfNeeded, before, after)
  marketDirty = false
end

local function refreshMarket()
  local usable = listUsableLeaves()
  local before = snapshotMults(usable)
  applyMarketChanges(before)
end

local function drainNpcDemand(dtSim)
  if dtSim <= 0 then return end
  local days = dtSim / SIM_SECONDS_PER_GAME_DAY
  local toEnd = {}
  for id, ep in pairs(episodes) do
    if not isLeafUsable(id) then
      toEnd[#toEnd + 1] = { id = id, reason = "unusable" }
    else
      local rate = tonumber(ep.npcRate) or 0
      ep.pool = (tonumber(ep.pool) or 0) - rate * days
      if ep.pool <= 1e-6 then
        toEnd[#toEnd + 1] = { id = id, reason = "npc" }
      end
    end
  end
  for _, item in ipairs(toEnd) do
    endSurge(item.id, item.reason)
  end
  for id, untilT in pairs(cooldownUntil) do
    if (tonumber(untilT) or 0) <= simTime then
      cooldownUntil[id] = nil
    end
  end
  if #toEnd > 0 or marketDirty then
    refreshMarket()
    tickCount = tickCount + 1
  end
end

local function nibblePlayerDemand(jobId)
  if not jobId or not JOB_LEAF_SET[jobId] then return false end
  local ep = episodes[jobId]
  if not ep then return false end

  local now = os.clock()
  local last = lastPlayerNibbleAt[jobId] or 0
  if (now - last) < PLAYER_NIBBLE_DEBOUNCE_SEC then
    return false
  end
  lastPlayerNibbleAt[jobId] = now
  lastTickJob = jobId

  ep.pool = (tonumber(ep.pool) or 0) - PLAYER_NIBBLE
  if ep.pool <= 1e-6 then
    local usable = listUsableLeaves()
    local before = snapshotMults(usable)
    endSurge(jobId, "player")
    applyMarketChanges(before)
    tickCount = tickCount + 1
    return true
  end
  return true
end

-- ── Save / Load ──

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function saveHeat(currentSavePath)
  if not careerActive() then return end
  if not loaded then return end
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end
  ensureSaveDir(currentSavePath)
  local data = {
    version = SAVE_VERSION,
    simTime = simTime,
    episodes = deepcopy(episodes),
    cooldownUntil = deepcopy(cooldownUntil),
    bandNotified = deepcopy(bandNotified),
    tickCount = tickCount,
    lastTickJob = lastTickJob,
    lastModified = os.time(),
  }
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
end

local function loadHeat()
  episodes = {}
  cooldownUntil = {}
  bandNotified = {}
  debugForce = {}
  lastPlayerNibbleAt = {}
  tickCount = 0
  lastTickJob = nil
  simTime = 0

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    local data = jsonReadFile(currentSavePath .. saveFile)
    if data and (data.version or 0) >= SAVE_VERSION then
      simTime = tonumber(data.simTime) or 0
      episodes = data.episodes or {}
      cooldownUntil = data.cooldownUntil or {}
      bandNotified = data.bandNotified or {}
      tickCount = data.tickCount or 0
      lastTickJob = data.lastTickJob
    else
      -- v2 pressure table (and older heat) do not map onto episodes — start fresh.
      episodes = {}
      cooldownUntil = {}
      bandNotified = {}
      tickCount = 0
      lastTickJob = nil
      simTime = 0
    end
  end

  loaded = true
  pendingTransientPush = true
end

local function safeLoadHeat()
  local ok, err = pcall(loadHeat)
  if not ok then
    loaded = false
    pendingTransientPush = false
    log("E", "activityHeat", "loadHeat failed: " .. tostring(err))
  end
end

-- ── Hooks ──

local function onUpdate(dtReal, dtSim, dtRaw)
  if not careerActive() then return end
  if not loaded then return end

  if pendingTransientPush then
    pendingTransientPush = false
    local ok, err = pcall(function()
      suspendedForChallenge = isChallengeActive()
      if suspendedForChallenge then
        if career_economyAdjuster and career_economyAdjuster.clearTransientMultipliers then
          career_economyAdjuster.clearTransientMultipliers()
        end
      else
        suppressDemandNotifs = true
        refreshMarket()
        syncAllDeliveryOffersToMarket()
        saveHeat()
      end
    end)
    suppressDemandNotifs = false
    if not ok then
      log("E", "activityHeat", "pendingTransientPush failed: " .. tostring(err))
    end
  end

  local challenge = isChallengeActive()
  if challenge ~= suspendedForChallenge then
    suspendedForChallenge = challenge
    if challenge then
      if career_economyAdjuster and career_economyAdjuster.clearTransientMultipliers then
        career_economyAdjuster.clearTransientMultipliers()
      end
    else
      refreshMarket()
    end
  end

  if suspendedForChallenge then return end

  local dt = tonumber(dtSim) or 0
  if dt <= 0 then return end
  simTime = simTime + dt
  drainNpcDemand(dt)
end

M.onPlayerAttributesChanged = function(change, reason)
  if not careerActive() or not loaded then return end
  if not change or not reason then return end
  local money = change.money
  if type(money) ~= "number" or money <= 0 then return end
  if isChallengeActive() then return end
  local jobId = classifyEarningTags(reason.tags)
  if not jobId then return end
  if nibblePlayerDemand(jobId) then
    saveHeat()
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveHeat(currentSavePath)
end

local function onCareerActivated()
  safeLoadHeat()
end

local function onExtensionLoaded()
  if careerActive() then
    safeLoadHeat()
  end
end

-- ── UI / introspection ──

local function getMarketSummary()
  local usableSet = {}
  for _, id in ipairs(listUsableLeaves()) do usableSet[id] = true end

  local branches = {}
  local hottest, softest = nil, nil

  for _, branch in ipairs(BRANCHES) do
    local leavesOut = {}
    local factors = {}
    for _, leaf in ipairs(branch.leaves) do
      local avail = usableSet[leaf.id] == true
      local factor = avail and effectiveMult(leaf.id) or 1.0
      local ep = episodes[leaf.id]
      local polarity = "neutral"
      if factor > 1.001 then polarity = "surge"
      elseif factor < 0.999 then polarity = "cooldown" end
      local row = {
        key = leaf.id,
        label = leaf.label,
        branch = branch.id,
        pressure = remainingFrac(ep), -- leftover demand 0–1 (debug / old field name)
        factor = factor,
        polarity = polarity,
        available = avail,
        remaining = remainingFrac(ep),
        durationDays = ep and ep.durationDays or nil,
      }
      leavesOut[#leavesOut + 1] = row
      if avail then
        factors[#factors + 1] = factor
        if not hottest or factor > hottest.factor then hottest = row end
        if not softest or factor < softest.factor then softest = row end
      end
    end

    local median = 1.0
    if #factors > 0 then
      table.sort(factors)
      local mid = math.ceil(#factors / 2)
      if #factors % 2 == 0 then
        median = (factors[mid] + factors[mid + 1]) / 2
      else
        median = factors[mid]
      end
    end

    local bPolarity = "neutral"
    if median > 1.001 then bPolarity = "surge"
    elseif median < 0.999 then bPolarity = "cooldown" end

    branches[#branches + 1] = {
      key = branch.id,
      label = branch.label,
      factor = median,
      polarity = bPolarity,
      available = #factors > 0,
      leaves = leavesOut,
    }
  end

  return {
    version = SAVE_VERSION,
    branches = branches,
    hottest = hottest and { key = hottest.key, label = hottest.label, factor = hottest.factor } or nil,
    softest = softest and { key = softest.key, label = softest.label, factor = softest.factor } or nil,
    hotThreshold = HOT_THRESHOLD,
    tickCount = tickCount,
    lastTickJob = lastTickJob,
  }
end

local function getDemandFactorForTags(tags)
  local jobId = classifyEarningTags(tags)
  if not jobId then return nil, 1.0 end
  return jobId, effectiveMult(jobId)
end

local function getDemandFactor(leafId)
  if not leafId or not JOB_LEAF_SET[leafId] then return 1.0 end
  return effectiveMult(leafId)
end

local function formatSurgeBonusText(jobIdOrFactor)
  local factor = jobIdOrFactor
  if type(jobIdOrFactor) == "string" then
    factor = getDemandFactor(jobIdOrFactor)
  end
  factor = tonumber(factor) or 1.0
  if factor < HOT_THRESHOLD then return "" end
  return string.format(" (+%d%% High Demand)", math.floor((factor - 1) * 100 + 0.5))
end

local function notifyHighDemandPayout(jobId, money, factor)
  if not notificationsEnabled() then return false end
  if isChallengeActive() then return false end
  factor = tonumber(factor) or 1.0
  money = tonumber(money) or 0
  if factor < HOT_THRESHOLD or money <= 0 then return false end

  local now = os.time()
  if lastPayoutNotifAt > 0 and (now - lastPayoutNotifAt) < PAYOUT_NOTIF_COOLDOWN_SEC then
    return false
  end

  local label = LEAF_LABEL[jobId] or jobId or "Job"
  local pct = math.floor((factor - 1.0) * 100 + 0.5)
  local bonus = money * (factor - 1.0) / factor
  if bonus < 1 then return false end

  if not (guihooks and guihooks.trigger) then return false end
  lastPayoutNotifAt = now
  pcall(guihooks.trigger, "PhoneLockNotification", {
    title = "High demand bonus",
    message = string.format("You earned about $%d extra on this %s payout.", math.floor(bonus + 0.5), label),
    meta = string.format("+%d%%", pct),
    kind = "success",
    source = "Market Watch",
    category = NOTIF_PREF_KEY,
    ttl = 6,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
  return true
end

local function getStateSummary()
  return {
    version = SAVE_VERSION,
    simTime = simTime,
    episodes = deepcopy(episodes),
    cooldownUntil = deepcopy(cooldownUntil),
    tickCount = tickCount,
    lastTickJob = lastTickJob,
    challengeSuspended = isChallengeActive(),
    debugForce = deepcopy(debugForce),
  }
end

local function debugDump()
  print("\n=== Opportunity Economy (activityHeat) ===")
  print(string.format("Sim days: %.2f | Events: %d | Last job: %s | Challenge: %s",
    simTime / SIM_SECONDS_PER_GAME_DAY, tickCount, tostring(lastTickJob), tostring(isChallengeActive())))
  local summary = getMarketSummary()
  for _, branch in ipairs(summary.branches or {}) do
    print(string.format("  [%s] median %+.0f%%", branch.label, ((branch.factor or 1) - 1) * 100))
    for _, leaf in ipairs(branch.leaves or {}) do
      if leaf.available then
        local ep = episodes[leaf.key]
        if ep then
          local daysLeft = 0
          if (tonumber(ep.npcRate) or 0) > 1e-6 then
            daysLeft = (tonumber(ep.pool) or 0) / ep.npcRate
          end
          print(string.format("    %-18s SURGE x%.2f (%+.0f%%)  pool=%.1f/%.1f  ~%.1fd left  npc/day=%.1f",
            leaf.label, leaf.factor or 1, ((leaf.factor or 1) - 1) * 100,
            tonumber(ep.pool) or 0, tonumber(ep.poolMax) or 0, daysLeft, tonumber(ep.npcRate) or 0))
        else
          local cd = cooldownUntil[leaf.key]
          local cdLeft = cd and math.max(0, (cd - simTime) / SIM_SECONDS_PER_GAME_DAY) or 0
          print(string.format("    %-18s baseline x%.2f%s",
            leaf.label, leaf.factor or 1,
            cdLeft > 0 and string.format("  cooldown %.1fd", cdLeft) or ""))
        end
      end
    end
  end
  print("==========================================\n")
end

local function forceSurge(jobId, magnitude)
  if not jobId then return false end
  local targets = {}
  if JOB_LEAF_SET[jobId] then
    targets[1] = jobId
  else
    for _, branch in ipairs(BRANCHES) do
      if branch.id == jobId then
        for _, leaf in ipairs(branch.leaves) do
          targets[#targets + 1] = leaf.id
        end
        break
      end
    end
  end
  if #targets == 0 then
    print(string.format("[activityHeat] Unknown job/branch '%s'", tostring(jobId)))
    return false
  end
  magnitude = clamp(tonumber(magnitude) or 1.5, TRANSIENT_FLOOR, TRANSIENT_CEIL)
  local usable = listUsableLeaves()
  local before = snapshotMults(usable)
  for _, id in ipairs(targets) do
    if isLeafAvailable(id) then
      debugForce[id] = magnitude
      if magnitude >= HOT_THRESHOLD then
        startSurge(id, { factor = magnitude, durationDays = 2.0 })
      else
        episodes[id] = nil
        debugForce[id] = magnitude
      end
    end
  end
  applyMarketChanges(before)
  saveHeat()
  print(string.format("[activityHeat] Forced surge on '%s' x%.2f", tostring(jobId), magnitude))
  return true
end

-- Console helper: nibble an active surge as if the player completed N jobs.
local function debugAddPressure(jobId, amount)
  if not jobId or not JOB_LEAF_SET[jobId] then return end
  local ep = episodes[jobId]
  if not ep then
    print(string.format("[activityHeat] '%s' is not surged", tostring(jobId)))
    return
  end
  local n = tonumber(amount) or 1.0
  lastPlayerNibbleAt[jobId] = nil
  ep.pool = (tonumber(ep.pool) or 0) - n
  if ep.pool <= 1e-6 then
    local usable = listUsableLeaves()
    local before = snapshotMults(usable)
    endSurge(jobId, "debug")
    applyMarketChanges(before)
  end
  saveHeat()
end

local function clearDebugForce()
  debugForce = {}
  refreshMarket()
end

-- ── Exports ──

M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded

M.getMarketSummary = getMarketSummary
M.getStateSummary = getStateSummary
M.getDemandFactorForTags = getDemandFactorForTags
M.getDemandFactor = getDemandFactor
M.formatSurgeBonusText = formatSurgeBonusText
M.HOT_THRESHOLD = HOT_THRESHOLD
M.notifyHighDemandPayout = notifyHighDemandPayout
M.classifyEarningTags = classifyEarningTags
M.getBranches = function() return deepcopy(BRANCHES) end
M.debugDump = debugDump
M.forceSurge = forceSurge
M.debugAddPressure = debugAddPressure
M.clearDebugForce = clearDebugForce
M.maybeShowOpportunityAdvert = maybeShowOpportunityAdvert
M.debugAddHeat = debugAddPressure

return M
