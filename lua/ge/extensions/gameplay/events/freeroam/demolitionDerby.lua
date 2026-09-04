-- Demolition Derby freeroam event controller.

-- Vehicles entering elimination zones are eliminated; when all AI gone → player wins.
-- Player can also be eliminated if playerCanBeEliminated is true.

local M = {}
local freConfig = require('gameplay/fre/config')
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
local derbyUi = require('gameplay/events/freeroam/demolitionDerbyUi')
local freeroamUtils = require('gameplay/events/freeroam/utils')

-- ── constants ──────────────────────────────────────────────────────────────
local CONFIG_FILENAME = "demo.config.json"
local DERBY_ARENA_BARRIERS_GROUP = "Derby Barriers"
local MAX_DAMAGE_FOR_DISPLAY = 50000
local MAX_SELECTABLE_AI_OPPONENTS = 9
local DEFAULT_XP_OF_MONEY = 0.25
local DEFAULT_AI_PERSONALITIES = {
  aggressor = {
    weight = 0.40,
    playerTargetWeightBonus = 0.22,
    aggressionMultiplier = 1.20,
    retargetIntervalMultiplier = 0.80,
    dangerMargin = 8,
    safeMargin = 12,
    preferReverseChance = 0.20,
  },
  opportunist = {
    weight = 0.35,
    playerTargetWeightBonus = 0.00,
    aggressionMultiplier = 1.00,
    retargetIntervalMultiplier = 1.00,
    dangerMargin = 10,
    safeMargin = 14,
    preferReverseChance = 0.35,
  },
  survivor = {
    weight = 0.25,
    playerTargetWeightBonus = -0.18,
    aggressionMultiplier = 0.82,
    retargetIntervalMultiplier = 1.35,
    dangerMargin = 13,
    safeMargin = 18,
    preferReverseChance = 0.70,
  }
}

-- ── state ──────────────────────────────────────────────────────────────────
local configData     = nil
local sitesData      = nil
local activeEvent    = nil
local activeEventCfg = nil
local eventActive    = false
local eventPhase     = "idle"
local activeEntryModeKey = "loaner"
local activeEntryModeCfg = nil
local activeWinnerRepairInsurance = false
local stagedAiCount  = 0
local spawnedAiIds   = {}
local spawnedAiInfo  = {}    -- { [vehId] = { model = "moonhawk", index = 1 } }
local eliminatedIds  = {}    -- { [vehId] = { placement = N } }
local playerEliminated = false
local playerPlacement  = nil
local totalParticipants = 0  -- AI + player
local nextPlacement     = 0  -- counts down from totalParticipants
local eventElapsedTime  = 0
local rewardsSettled    = false
local lastRewardSummary = nil
local playerInventoryId = nil
local playerDerbyVehicleId = nil
local originalPlayerVehicleId = nil
local playerLoanerVehicleId = nil
local stagedPlayerTransform = nil -- captured when starting event from staging
local firstAiEliminationElapsed = nil
local eventFinishReason = nil
local noContactTimer = 0
local lastPlayerRawDamage = nil
local lastAiRawDamageById = {}
local derbyDamageScoring = {
  damageDealtById = {},
  lastRawDamageById = {},
  scoreDataById = {},
}

-- Resolved spatial data
local resolvedSpots     = nil
local resolvedPlayZone  = nil
local resolvedElimZones = nil

-- Elimination config
local STATIONARY_ELIMINATION_TIME = 30.0
local STATIONARY_SPEED_THRESHOLD = 1.0
local DEFAULT_NO_CONTACT_TIMEOUT_SECONDS = 30.0
local DEFAULT_NO_CONTACT_WARNING_SECONDS = 10.0
local NO_CONTACT_DAMAGE_THRESHOLD = 1.0
local NO_CONTACT_DISTANCE_METERS = 8.0
local NO_CONTACT_TOUCH_DISTANCE_METERS = 3.5
local NO_CONTACT_TOUCH_REL_SPEED_MPS = 1.5
local DERBY_DAMAGE_ATTRIBUTION_RADIUS_METERS = 10.0
local DERBY_TIMEOUT_HEALTH_WEIGHT = 0.5
local DERBY_TIMEOUT_DAMAGE_DEALT_WEIGHT = 0.5
-- --- Derby flip unstuck (disabled)
--[[
local RADIAL_UNSTUCK_MAX_SPEED_KMH = 5.0
local RADIAL_UNSTUCK_MAX_SPEED_MPS = RADIAL_UNSTUCK_MAX_SPEED_KMH / 3.6
local RADIAL_UNSTUCK_CLEARANCE_METERS = 7.0
local RADIAL_UNSTUCK_SEARCH_STEP_METERS = 2.0
local RADIAL_UNSTUCK_SEARCH_MAX_RADIUS_METERS = 26.0
local RADIAL_UNSTUCK_MIN_RING_SAMPLES = 12
local RADIAL_UNSTUCK_MAX_RING_SAMPLES = 48
]]
local AI_STATIONARY_RECOVERY_TIME = 2.5
local stationaryTimers = {} -- { [vehId] = timeSpentStationary }

-- Zone debug drawing state
local drawZonesActive = false
local forceZoneDebugDraw = false
local forceZoneDebugEventKey = nil
local forceZoneDebugResolvedKey = nil
-- AI behavior state
local aiActivated       = false    -- whether AI chase behavior has been activated
local aiActivationDelay  = 2.0     -- seconds after spawn before AI starts chasing
local aiActivationTimer  = 0       -- countdown for activation
local trafficSuppressedForEvent = false
local derbyConfigTypePoolCache = nil
local derbyLevelId = nil
local derbyLevelReady = false
local derbyAvailable = false
local derbyArenaBarriersVisible = nil
local derbyArenaBarriersGroupName = nil

-- ── helpers ────────────────────────────────────────────────────────────────
local function _log(level, msg)
  if _G.log then
    _G.log(level, "demolitionDerby", msg)
  end
end

local function ordinal(n)
  if n % 100 >= 11 and n % 100 <= 13 then return n .. "th" end
  local d = n % 10
  if d == 1 then return n .. "st"
  elseif d == 2 then return n .. "nd"
  elseif d == 3 then return n .. "rd"
  else return n .. "th" end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function parseConsoleBool(v)
  if type(v) == "boolean" then return v end
  if type(v) == "number" then return v ~= 0 end
  if type(v) == "string" then
    local s = tostring(v):lower()
    if s == "1" or s == "true" or s == "on" or s == "yes" then return true end
    if s == "0" or s == "false" or s == "off" or s == "no" then return false end
  end
  return nil
end

local function pushRewardMessage(msg, icon)
  if ui_message and type(msg) == "string" and msg ~= "" then
    ui_message(msg, 8, "demoReward", icon or "check")
  end
end

local function saveCareerProgress(reason)
  if career_saveSystem and career_saveSystem.saveCurrent then
    local ok, err = pcall(function() career_saveSystem.saveCurrent() end)
    if not ok then
      _log("W", "Failed to save derby career progress" .. (reason and (" after " .. tostring(reason)) or "") .. ": " .. tostring(err))
    end
  end
end

local function getElapsedEventTime()
  return eventElapsedTime
end

local function resolveSessionInventoryFromSpawnId(subjectID)
  if not subjectID then
    return subjectID
  end
  if career_modules_business_businessInventory then
    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(subjectID)
    if businessId and vehicleId then
      local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
      if jobId then
        return career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
      end
      return career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
    end
  end
  return career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
end

local function mergeNested(base, override)
  local out = {}
  if type(base) == "table" then
    for k, v in pairs(base) do
      if type(v) == "table" then
        local nested = {}
        for nk, nv in pairs(v) do
          nested[nk] = nv
        end
        out[k] = nested
      else
        out[k] = v
      end
    end
  end
  if type(override) == "table" then
    for k, v in pairs(override) do
      if type(v) == "table" and type(out[k]) == "table" then
        for nk, nv in pairs(v) do
          out[k][nk] = nv
        end
      else
        out[k] = v
      end
    end
  end
  return out
end

local function getAiPersonalityProfiles()
  local cfg = activeEventCfg and activeEventCfg.aiPersonalityProfiles
  if type(cfg) ~= "table" then
    return DEFAULT_AI_PERSONALITIES
  end
  return mergeNested(DEFAULT_AI_PERSONALITIES, cfg)
end

local function pickAiPersonalityName()
  local profiles = getAiPersonalityProfiles()
  local totalWeight = 0
  for _, profile in pairs(profiles) do
    totalWeight = totalWeight + math.max(0, tonumber(profile.weight) or 0)
  end
  if totalWeight <= 0 then
    return "opportunist"
  end

  local roll = math.random() * totalWeight
  local accum = 0
  for name, profile in pairs(profiles) do
    accum = accum + math.max(0, tonumber(profile.weight) or 0)
    if roll <= accum then
      return name
    end
  end
  return "opportunist"
end

local function getAiPersonality(aiVehId)
  local info = spawnedAiInfo[aiVehId]
  local profileName = info and info.personalityName or "opportunist"
  local profiles = getAiPersonalityProfiles()
  return profiles[profileName] or profiles.opportunist or DEFAULT_AI_PERSONALITIES.opportunist
end

local function getAiRetargetInterval(aiVehId)
  local base = tonumber(activeEventCfg and activeEventCfg.aiRetargetInterval) or 8
  base = clamp(base, 0.75, 30)
  local personality = getAiPersonality(aiVehId)
  local mult = clamp(tonumber(personality.retargetIntervalMultiplier) or 1, 0.65, 1.35)
  local jitter = 0.9 + (math.random() * 0.2)
  return math.max(0.75, base * mult * jitter)
end

local function getEntryModes(cfg)
  local modes = cfg and cfg.entryModes
  if type(modes) == "table" then
    return modes
  end
  return {
    loaner = {
      label = "Register as Driver",
      entryFee = 1000,
      rewardBase = tonumber(cfg and cfg.reward) or 500,
      rewardPerAi = 250,
      playerPool = "rlsDerby100",
      aiPool = "rlsDerby100",
      loaner = true
    },
    ownCar = {
      label = "Enter Own Car",
      entryFee = 0,
      rewardBase = 10000,
      rewardPerAi = 750,
      aiPool = "rlsDerby100",
      requireUninsured = true,
      persistDamage = true
    }
  }
end

local function getEntryModeConfig(cfg, modeKey)
  local modes = getEntryModes(cfg)
  local key = tostring(modeKey or "")
  local mode = modes[key]
  if type(mode) ~= "table" then
    key = "loaner"
    mode = modes.loaner
  end
  if type(mode) ~= "table" then
    for k, v in pairs(modes) do
      if type(v) == "table" then
        key = k
        mode = v
        break
      end
    end
  end
  return key, mode or {}
end

local function getEventEconomyTypes(cfg)
  local types = cfg and cfg.type
  if type(types) ~= "table" or #types == 0 then
    return { "demo" }
  end
  return types
end

local function getDerbyEconomyMultiplier(cfg)
  if freeroamUtils and freeroamUtils.calculateAverageMultiplier then
    return freeroamUtils.calculateAverageMultiplier(getEventEconomyTypes(cfg))
  end
  if career_economyAdjuster then
    return career_economyAdjuster.getEffectiveSectionMultiplier(getEventEconomyTypes(cfg)) or 1.0
  end
  return 1.0
end

local function getWinnerRepairInsuranceCfg(cfg)
  cfg = cfg or activeEventCfg
  local block = cfg and cfg.winnerRepairInsurance
  if type(block) ~= "table" or block.enabled == false then
    return nil
  end
  local pct = tonumber(block.rewardCutPercent) or 50
  pct = math.max(0, math.min(100, pct))
  return {
    enabled = true,
    rewardCutPercent = pct,
    defaultSelected = block.defaultSelected == true,
  }
end

local function isWinnerRepairInsuranceAvailable(cfg, modeKey)
  local ins = getWinnerRepairInsuranceCfg(cfg)
  if not ins then
    return false
  end
  local _, mode = getEntryModeConfig(cfg, modeKey)
  return mode and mode.persistDamage == true
end

local function calcWinnerRepairInsuranceFee(grossMoney, cfg)
  local ins = getWinnerRepairInsuranceCfg(cfg)
  if not ins or ins.rewardCutPercent <= 0 then
    return 0
  end
  return math.max(0, math.floor(((tonumber(grossMoney) or 0) * ins.rewardCutPercent / 100) + 0.5))
end

local function buildWinnerRepairInsurancePayload(cfg, modeKey, selected)
  if not isWinnerRepairInsuranceAvailable(cfg, modeKey) then
    return {
      winnerRepairInsuranceAvailable = false,
      winnerRepairInsuranceSelected = false,
      winnerRepairInsurancePercent = 0,
    }
  end
  local ins = getWinnerRepairInsuranceCfg(cfg)
  local isSelected = selected
  if isSelected == nil then
    isSelected = ins.defaultSelected
  end
  return {
    winnerRepairInsuranceAvailable = true,
    winnerRepairInsuranceSelected = isSelected == true,
    winnerRepairInsurancePercent = ins.rewardCutPercent,
  }
end

local function buildModeOptions(cfg, aiCount)
  local modes = getEntryModes(cfg)
  local out = {}
  for key, mode in pairs(modes) do
    if type(mode) == "table" then
      local base = tonumber(mode.rewardBase) or tonumber(cfg and cfg.reward) or 0
      local perAi = tonumber(mode.rewardPerAi) or 0
      local grossReward = base + (perAi * math.max(1, tonumber(aiCount) or 1))
      local economyMult = getDerbyEconomyMultiplier(cfg)
      table.insert(out, {
        key = key,
        label = mode.label or key,
        description = mode.description or "",
        entryFee = math.max(0, math.floor(tonumber(mode.entryFee) or 0)),
        rewardBase = math.max(0, math.floor(tonumber(mode.rewardBase) or tonumber(cfg and cfg.reward) or 0)),
        rewardPerAi = math.max(0, math.floor(tonumber(mode.rewardPerAi) or 0)),
        rewardPreview = math.max(0, math.floor(grossReward * economyMult + 0.5)),
        requireUninsured = mode.requireUninsured == true,
        loaner = mode.loaner ~= false and key == "loaner" or mode.loaner == true
      })
    end
  end
  table.sort(out, function(a, b)
    if a.key == "loaner" then return true end
    if b.key == "loaner" then return false end
    return tostring(a.key) < tostring(b.key)
  end)
  return out
end

local function getModeRewardBase(participantCount)
  local cfg = activeEntryModeCfg or {}
  local fallback = tonumber(activeEventCfg and activeEventCfg.reward) or 0
  local base = tonumber(cfg.rewardBase) or fallback
  local perAi = tonumber(cfg.rewardPerAi) or 0
  local aiCount = math.max(1, math.floor((participantCount or 1) - 1))
  return math.max(0, base + (perAi * aiCount))
end

local function getModeXpReward(money)
  local cfg = activeEntryModeCfg or {}
  local explicitXp = tonumber(cfg.xpReward or cfg.rewardXp or cfg.xp)
  if explicitXp and explicitXp >= 0 then
    return math.floor(explicitXp + 0.5)
  end
  return math.max(0, math.floor(((tonumber(money) or 0) * DEFAULT_XP_OF_MONEY) + 0.5))
end

local function settleCareerRewards(playerWasEliminated, playerPlace, eliminationReason)
  if rewardsSettled then return lastRewardSummary end
  rewardsSettled = true

  local place = tonumber(playerPlace)
  if not place or place < 1 then
    place = totalParticipants
  end
  place = math.floor(place)

  local participantCount = math.max(1, math.floor(totalParticipants or 1))
  local eligible = place == 1

  local summary = {
    money = 0,
    xp = 0,
    eligible = eligible,
    noRewardDetail = nil,
    place = place,
    participantCount = participantCount,
    modeKey = activeEntryModeKey,
    modeLabel = activeEntryModeCfg and activeEntryModeCfg.label or activeEntryModeKey,
    entryFee = math.max(0, math.floor(tonumber(activeEntryModeCfg and activeEntryModeCfg.entryFee) or 0)),
  }
  lastRewardSummary = summary

  if not (career_career and career_career.isActive and career_career.isActive()) then
    summary.noRewardDetail = "Rewards are only available in Career mode."
    return summary
  end
  if not (career_modules_payment and career_modules_payment.reward) then
    summary.noRewardDetail = "Reward system unavailable."
    return summary
  end

  local elapsed = getElapsedEventTime()

  if gameplay_events_freContracts_race and gameplay_events_freContracts_race.onFreeroamRaceCompleted then
    gameplay_events_freContracts_race.onFreeroamRaceCompleted({
      raceName = activeEvent,
      finishTime = elapsed,
      disciplineIds = { "demo" },
      invalidLap = not eligible,
      resultMetrics = {
        placement = place,
        totalParticipants = participantCount,
        eliminated = playerWasEliminated == true,
        eliminationReason = eliminationReason
      }
    })
  end

  if not eligible then
    summary.noRewardDetail = "1st place required for rewards."
    pushRewardMessage(string.format("%s place. No payout (1st place required).", ordinal(place)), "warning")
    return summary
  end

  local eventReward = getModeRewardBase(participantCount)
  if eventReward <= 0 then
    summary.noRewardDetail = "No payout configured for this event."
    pushRewardMessage(string.format("%s place. No payout configured.", ordinal(place)), "warning")
    return summary
  end

  local freMods = nil
  if gameplay_events_freContracts_race and gameplay_events_freContracts_race.calculateRewardModifiers then
    freMods = gameplay_events_freContracts_race.calculateRewardModifiers({ "demo" })
  end
  local xpMult = 1
  local disciplineMods = freMods and freMods.disciplineMultipliers and freMods.disciplineMultipliers.demo
  local levelMult = tonumber(disciplineMods and disciplineMods.skillMultiplier) or 1
  if disciplineMods then
    xpMult = tonumber(disciplineMods.xpMultiplier) or 1
  end

  local economyMult = getDerbyEconomyMultiplier(activeEventCfg)
  local grossMoney = math.floor((eventReward * economyMult * levelMult) + 0.5)
  grossMoney = math.max(0, grossMoney)

  local repairCut = 0
  if activeWinnerRepairInsurance then
    repairCut = calcWinnerRepairInsuranceFee(grossMoney, activeEventCfg)
  end
  local money = math.max(0, grossMoney - repairCut)

  local xpBaseMoney = math.max(0, eventReward * economyMult)
  local xp = math.floor((getModeXpReward(xpBaseMoney) * xpMult) + 0.5)
  xp = math.max(0, xp)

  if money <= 0 and xp <= 0 then
    summary.noRewardDetail = "No payout generated."
    pushRewardMessage(string.format("%s place. No payout generated.", ordinal(place)), "warning")
    return summary
  end

  local rewardData = {
    money = { amount = money, canBeNegative = false },
    [freConfig.getSkillKey("demo") or "careerSkills-mayhem"] = { amount = xp }
  }
  career_modules_payment.reward(rewardData, {
    label = string.format("Demolition Derby: %s", tostring((activeEventCfg and activeEventCfg.label) or "Event")),
    tags = { "gameplay", "reward", "fre", "demo" }
  }, true)

  summary.money = money
  summary.grossMoney = grossMoney
  summary.repairCut = repairCut
  summary.winnerRepairInsurance = activeWinnerRepairInsurance
  summary.xp = xp
  summary.rewardScales = {
    aiCountMultiplier = 1,
    durationMoneyMultiplier = 1,
    durationXpMultiplier = 1,
    durationLabel = "No duration scaling",
    economyMultiplier = economyMult,
    levelMultiplier = levelMult,
    modeKey = activeEntryModeKey,
    modeLabel = activeEntryModeCfg and activeEntryModeCfg.label or activeEntryModeKey,
    entryFee = math.max(0, math.floor(tonumber(activeEntryModeCfg and activeEntryModeCfg.entryFee) or 0)),
    grossRewardBase = eventReward,
  }

  local rewardMsg = string.format("%s place. Reward: $%d | Demo XP: %d", ordinal(place), money, xp)
  if repairCut > 0 then
    rewardMsg = string.format("%s place. Reward: $%d (repair cut $%d) | Demo XP: %d", ordinal(place), money, repairCut, xp)
  end
  pushRewardMessage(rewardMsg, "check")
  return summary
end

local function deepMerge(defaults, overrides)
  local result = {}
  if type(defaults) == "table" then
    for k, v in pairs(defaults) do result[k] = v end
  end
  if type(overrides) == "table" then
    for k, v in pairs(overrides) do result[k] = v end
  end
  return result
end

-- ── data loading ───────────────────────────────────────────────────────────
local function loadConfigData(logOnFailure)
  local levelId = getCurrentLevelIdentifier()
  if not levelId or levelId == "" then return nil end
  local path = "levels/" .. levelId .. "/" .. CONFIG_FILENAME
  local data = jsonReadFile(path)
  if type(data) ~= "table" then
    if logOnFailure ~= false then
      _log("W", "Could not load " .. path)
    end
    return nil
  end
  return data
end

local function loadSitesData(sitesFile, logOnFailure)
  local levelId = getCurrentLevelIdentifier()
  if not levelId or levelId == "" then return nil end
  local filename = sitesFile or "demolition.sites.json"
  local path = "levels/" .. levelId .. "/" .. filename
  local data = jsonReadFile(path)
  if type(data) ~= "table" then
    if logOnFailure ~= false then
      _log("W", "Could not load " .. path)
    end
    return nil
  end
  return data
end

local function listSceneObjectChildren(obj)
  local out = {}
  if not obj or not obj.getCount then
    return out
  end
  local ok, count = pcall(function() return obj:getCount() end)
  if not ok or not count then
    return out
  end
  for i = 0, count - 1 do
    local childOk, child = pcall(function() return obj:getObject(i) end)
    if childOk and child then
      table.insert(out, child)
    end
  end
  return out
end

local function setDerbyArenaBarrierObjectState(obj, hidden)
  if not obj then
    return
  end
  local isHidden = hidden == true
  if obj.setHidden then
    pcall(function() obj:setHidden(isHidden) end)
  end
  if obj.setField then
    pcall(function() obj:setField('isRenderEnabled', 0, isHidden and '0' or '1') end)
  end
  if isHidden then
    if obj.disableCollision then
      pcall(function() obj:disableCollision() end)
    end
  elseif obj.enableCollision then
    pcall(function() obj:enableCollision() end)
  end
  for _, child in ipairs(listSceneObjectChildren(obj)) do
    setDerbyArenaBarrierObjectState(child, hidden)
  end
end

local function getDerbyArenaBarriersGroupName()
  local configured = (activeEventCfg and activeEventCfg.arenaBarriersGroup)
    or (configData and configData.arenaBarriersGroup)
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return DERBY_ARENA_BARRIERS_GROUP
end

local function isDerbyArenaBarriersPhaseActive()
  return eventPhase == "gridStaged"
      or eventPhase == "countdown"
      or eventPhase == "running"
      or eventPhase == "results"
end

local function setDerbyArenaBarriersVisible(visible)
  local wantVisible = visible == true
  local groupName = getDerbyArenaBarriersGroupName()
  if derbyArenaBarriersVisible == wantVisible and derbyArenaBarriersGroupName == groupName then
    return wantVisible
  end

  local root = scenetree.findObject(groupName)
  if not root then
    if wantVisible then
      _log("W", "Derby arena barriers group not found: " .. groupName)
    end
    return false
  end

  setDerbyArenaBarrierObjectState(root, not wantVisible)
  if be and be.reloadCollision then
    pcall(function() be:reloadCollision() end)
  end
  derbyArenaBarriersVisible = wantVisible
  derbyArenaBarriersGroupName = groupName
  return true
end

local function hideDerbyArenaBarriers()
  setDerbyArenaBarriersVisible(false)
end

local function showDerbyArenaBarriers()
  setDerbyArenaBarriersVisible(true)
end

local function syncDerbyArenaBarriersVisibility()
  setDerbyArenaBarriersVisible(isDerbyArenaBarriersPhaseActive())
end

local function refreshDerbyForCurrentLevel()
  local levelId = getCurrentLevelIdentifier()
  if not levelId or levelId == "" then
    derbyLevelId = nil
    derbyLevelReady = true
    derbyAvailable = false
    configData = nil
    sitesData = nil
    hideDerbyArenaBarriers()
    return false
  end
  if derbyLevelId == levelId and derbyLevelReady then
    return derbyAvailable
  end

  derbyLevelId = levelId
  derbyLevelReady = true
  derbyArenaBarriersVisible = nil
  configData = loadConfigData(false)
  if not configData then
    derbyAvailable = false
    sitesData = nil
    hideDerbyArenaBarriers()
    return false
  end

  sitesData = loadSitesData(configData.sitesFile, false)
  if not sitesData then
    configData = nil
    derbyAvailable = false
    hideDerbyArenaBarriers()
    return false
  end

  derbyAvailable = true
  syncDerbyArenaBarriersVisibility()
  return true
end

local function getEventConfig(eventKey)
  if not configData or not configData.events then return nil end
  local eventDef = configData.events[eventKey]
  if not eventDef then return nil end
  local defaults = configData.defaults or {}
  return deepMerge(defaults, eventDef)
end

local function getAvailableEventKeys()
  if not configData or not configData.events then return {} end
  local keys = {}
  for k, _ in pairs(configData.events) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

-- ── spatial resolution (from sites file) ───────────────────────────────────
local function resolveParkingSpots(prefix)
  if not sitesData or not sitesData.parkingSpots then return {} end
  local spots = {}
  for _, spot in ipairs(sitesData.parkingSpots) do
    local name = spot and spot.name or ""
    if type(name) == "string" and name:sub(1, #prefix) == prefix then
      table.insert(spots, spot)
    end
  end
  table.sort(spots, function(a, b)
    local an = tonumber((a.name or ""):match("(%d+)$")) or math.huge
    local bn = tonumber((b.name or ""):match("(%d+)$")) or math.huge
    return an < bn
  end)
  return spots
end

local function resolveParkingSpotByName(spotName)
  if type(spotName) ~= "string" or spotName == "" then return nil end
  if not sitesData or not sitesData.parkingSpots then return nil end
  for _, spot in ipairs(sitesData.parkingSpots) do
    if spot and spot.name == spotName then
      return spot
    end
  end
  return nil
end

local function resolveZone(zoneName)
  if not sitesData or not sitesData.zones then return nil end
  for _, zone in ipairs(sitesData.zones) do
    if zone and zone.name == zoneName then
      return zone
    end
  end
  return nil
end

local function resolveZones(zoneNames)
  if type(zoneNames) ~= "table" then return {} end
  local zones = {}
  for _, name in ipairs(zoneNames) do
    local zone = resolveZone(name)
    if zone then
      table.insert(zones, zone)
    else
      _log("W", "Zone not found in sites file: " .. tostring(name))
    end
  end
  return zones
end

-- Resolve all spatial data for a given event config
local function resolveAllSpatialData(cfg)
  if not cfg then return end
  local prefix = cfg.spawnPrefix or "Spawn"
  resolvedSpots = resolveParkingSpots(prefix)
  local playZoneName = cfg.playZone
  if playZoneName then
    resolvedPlayZone = resolveZone(playZoneName)
  end
  resolvedElimZones = resolveZones(cfg.eliminationZones or {})
end

local function clearSpatialData()
  resolvedSpots = nil
  resolvedPlayZone = nil
  resolvedElimZones = nil
end

local function restoreTrafficAfterEvent()
  if not trafficSuppressedForEvent then
    return
  end

  if gameplay_traffic then
    local settingsAmount = settings.getValue('trafficAmount') == 0 and getMaxVehicleAmount() or
                             settings.getValue('trafficAmount')
    local pooledAmount = settings.getValue('trafficExtraAmount') or 0
    gameplay_traffic.setActiveAmount((settingsAmount or 0) + (pooledAmount or 0), settingsAmount)
  end

  trafficSuppressedForEvent = false
end

-- ── polygon point-in-zone test (2D, ignores Z) ────────────────────────────
local function isPointInPolygon2D(px, py, vertices)
  if not vertices or #vertices < 3 then return false end
  local inside = false
  local n = #vertices
  local j = n
  for i = 1, n do
    local xi, yi = vertices[i][1], vertices[i][2]
    local xj, yj = vertices[j][1], vertices[j][2]
    if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

local function isInsideZone(pos, zone)
  if not zone or not zone.vertices or #zone.vertices < 3 then return false end
  return isPointInPolygon2D(pos.x, pos.y, zone.vertices)
end

local function isInsideAnyEliminationZone(pos)
  if not resolvedElimZones then return false end
  for _, zone in ipairs(resolvedElimZones) do
    if isInsideZone(pos, zone) then
      return true
    end
  end
  return false
end

local function isInsidePlayZone(pos)
  if not resolvedPlayZone then return true end
  return isInsideZone(pos, resolvedPlayZone)
end

local function getPlayzoneCentroid()
  if not resolvedPlayZone or not resolvedPlayZone.vertices or #resolvedPlayZone.vertices < 3 then 
    return vec3(0, 0, 0) 
  end
  local sumX, sumY = 0, 0
  for _, v in ipairs(resolvedPlayZone.vertices) do
    sumX = sumX + v[1]
    sumY = sumY + v[2]
  end
  local count = #resolvedPlayZone.vertices
  return vec3(sumX / count, sumY / count, 0)
end

local function distanceToLineSegment2D(px, py, x1, y1, x2, y2)
  local l2 = (x1 - x2)^2 + (y1 - y2)^2
  if l2 == 0 then return math.sqrt((px - x1)^2 + (py - y1)^2) end
  local t = math.max(0, math.min(1, ((px - x1) * (x2 - x1) + (py - y1) * (y2 - y1)) / l2))
  local projX = x1 + t * (x2 - x1)
  local projY = y1 + t * (y2 - y1)
  return math.sqrt((px - projX)^2 + (py - projY)^2)
end

local function getDistanceToPlayZoneEdge(pos)
  if not resolvedPlayZone or not resolvedPlayZone.vertices then return math.huge end
  local minD = math.huge
  local n = #resolvedPlayZone.vertices
  local j = n
  for i = 1, n do
    local d = distanceToLineSegment2D(pos.x, pos.y, resolvedPlayZone.vertices[i][1], resolvedPlayZone.vertices[i][2], resolvedPlayZone.vertices[j][1], resolvedPlayZone.vertices[j][2])
    if d < minD then minD = d end
    j = i
  end
  return minD
end

local function getPlayZoneBounds2D()
  if not resolvedPlayZone or not resolvedPlayZone.vertices or #resolvedPlayZone.vertices < 3 then
    return nil
  end

  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge
  for _, v in ipairs(resolvedPlayZone.vertices) do
    minX = math.min(minX, v[1])
    maxX = math.max(maxX, v[1])
    minY = math.min(minY, v[2])
    maxY = math.max(maxY, v[2])
  end

  if minX == math.huge or minY == math.huge then
    return nil
  end

  return minX, maxX, minY, maxY
end

-- --- Derby flip unstuck (disabled)
--[[
local function isPointClearOfVehicles(pos, ignoreVehId, clearanceMeters)
  local vehicles = (type(getAllVehicles) == "function") and getAllVehicles() or nil
  if type(vehicles) ~= "table" then
    return true
  end

  local minDist = tonumber(clearanceMeters) or RADIAL_UNSTUCK_CLEARANCE_METERS
  minDist = math.max(0.5, minDist)
  local minDistSq = minDist * minDist

  for _, veh in ipairs(vehicles) do
    if veh and veh.getPosition then
      local vehId = nil
      if veh.getID then
        vehId = veh:getID()
      elseif veh.getId then
        vehId = veh:getId()
      end
      if not ignoreVehId or vehId ~= ignoreVehId then
        local vPos = veh:getPosition()
        if vPos then
          local dx = vPos.x - pos.x
          local dy = vPos.y - pos.y
          if (dx * dx + dy * dy) < minDistSq then
            return false
          end
        end
      end
    end
  end

  return true
end

local function isUnstuckPointValid(pos, ignoreVehId)
  if not pos then
    return false
  end
  if not isInsidePlayZone(pos) then
    return false
  end
  if isInsideAnyEliminationZone(pos) then
    return false
  end
  return isPointClearOfVehicles(pos, ignoreVehId, RADIAL_UNSTUCK_CLEARANCE_METERS)
end

local function findNearestFreeUnstuckPoint(originPos, zBase, ignoreVehId)
  if not originPos then
    return nil
  end

  local base = vec3(originPos.x, originPos.y, zBase or originPos.z or 0)
  if isUnstuckPointValid(base, ignoreVehId) then
    return base
  end

  local angleOffset = math.random() * math.pi * 2
  local radius = RADIAL_UNSTUCK_SEARCH_STEP_METERS
  while radius <= RADIAL_UNSTUCK_SEARCH_MAX_RADIUS_METERS do
    local circumference = 2 * math.pi * radius
    local samples = math.floor(circumference / math.max(0.1, RADIAL_UNSTUCK_SEARCH_STEP_METERS))
    samples = math.max(RADIAL_UNSTUCK_MIN_RING_SAMPLES, math.min(RADIAL_UNSTUCK_MAX_RING_SAMPLES, samples))

    for i = 1, samples do
      local a = angleOffset + ((i - 1) / samples) * math.pi * 2
      local p = vec3(base.x + math.cos(a) * radius, base.y + math.sin(a) * radius, base.z)
      if isUnstuckPointValid(p, ignoreVehId) then
        return p
      end
    end

    radius = radius + RADIAL_UNSTUCK_SEARCH_STEP_METERS
  end

  return nil
end

local function pickUnstuckPointInsidePlayZone(currentPos, ignoreVehId)
  if not resolvedPlayZone or not resolvedPlayZone.vertices or #resolvedPlayZone.vertices < 3 then
    return nil
  end

  local minX, maxX, minY, maxY = getPlayZoneBounds2D()
  if not minX then
    return nil
  end

  local zBase = currentPos and currentPos.z or 0
  local bestPoint = nil
  local bestScore = -math.huge
  for _ = 1, 80 do
    local px = minX + math.random() * (maxX - minX)
    local py = minY + math.random() * (maxY - minY)
    local p = vec3(px, py, zBase)
    if isUnstuckPointValid(p, ignoreVehId) then
      local moveDist = currentPos and (p - currentPos):length() or 0
      local edgeDist = getDistanceToPlayZoneEdge(p)
      if moveDist >= 6 then
        local score = edgeDist + math.min(moveDist, 25) * 0.05
        if score > bestScore then
          bestScore = score
          bestPoint = p
        end
      end
    end
  end

  if bestPoint then
    return bestPoint
  end

  local center = getPlayzoneCentroid()
  local fallback = vec3(center.x, center.y, zBase)
  local nearestFallback = findNearestFreeUnstuckPoint(fallback, zBase, ignoreVehId)
  if nearestFallback then
    return nearestFallback
  end

  if currentPos then
    return findNearestFreeUnstuckPoint(currentPos, zBase, ignoreVehId)
  end

  return nil
end
]]

local function getVehiclePos(vehId)
  local obj = be:getObjectByID(vehId)
  if not obj then return nil end
  return obj:getPosition()
end

local function despawnVehicle(vehId)
  local obj = be:getObjectByID(vehId)
  if obj then
    obj:delete()
  end
end

-- ── damage query ───────────────────────────────────────────────────────────
local function getDamageDisplayMax(isPlayer)
  local cfg = activeEventCfg or {}
  local maxDmg
  if isPlayer then
    maxDmg = tonumber(cfg.maxDamageForDisplayPlayer)
  else
    maxDmg = tonumber(cfg.maxDamageForDisplayAi)
  end
  if not maxDmg then
    maxDmg = tonumber(cfg.maxDamageForDisplay)
  end
  if not maxDmg or maxDmg <= 0 then
    maxDmg = MAX_DAMAGE_FOR_DISPLAY
  end
  return maxDmg
end

local function getVehicleDamageNormalized(vehId, isPlayer)
  if not map or not map.objects or not map.objects[vehId] then return 0 end
  local raw = map.objects[vehId].damage or 0
  local maxDmg = getDamageDisplayMax(isPlayer == true)
  return math.min(100, (raw / maxDmg) * 100)
end

-- ── vehicle pool ───────────────────────────────────────────────────────────
local function getRawVehicleDamage(vehId)
  if not map or not map.objects or not map.objects[vehId] then return 0 end
  return tonumber(map.objects[vehId].damage) or 0
end

local function getNoContactTimeoutSeconds()
  local timeout = tonumber(activeEventCfg and activeEventCfg.noContactTimeoutSeconds)
  if timeout == nil then timeout = DEFAULT_NO_CONTACT_TIMEOUT_SECONDS end
  return math.max(0, timeout)
end

local function getNoContactWarningSeconds()
  local warning = tonumber(activeEventCfg and activeEventCfg.noContactWarningSeconds)
  if warning == nil then warning = DEFAULT_NO_CONTACT_WARNING_SECONDS end
  return math.max(0, warning)
end

local function resetNoContactState()
  noContactTimer = 0
  derbyUi.clearDerbyCountdownWarnings()
  lastPlayerRawDamage = playerDerbyVehicleId and getRawVehicleDamage(playerDerbyVehicleId) or nil
  lastAiRawDamageById = {}
  for _, vehId in ipairs(spawnedAiIds) do
    lastAiRawDamageById[vehId] = getRawVehicleDamage(vehId)
  end
end

local function detectPlayerDerbyContact()
  if not playerDerbyVehicleId then return false end
  local playerObj = be:getObjectByID(playerDerbyVehicleId)
  if not playerObj then return false end

  local playerPos = playerObj:getPosition()
  local playerVel = playerObj:getVelocity()
  local playerRawDamage = getRawVehicleDamage(playerDerbyVehicleId)
  local playerDamageDelta = lastPlayerRawDamage and (playerRawDamage - lastPlayerRawDamage) or 0
  lastPlayerRawDamage = playerRawDamage

  local playerNearOpponent = false
  local nearbyOpponentDamaged = false
  local touchedOpponent = false

  for _, vehId in ipairs(spawnedAiIds) do
    if not eliminatedIds[vehId] then
      local aiObj = be:getObjectByID(vehId)
      local aiRawDamage = getRawVehicleDamage(vehId)
      local aiDamageDelta = lastAiRawDamageById[vehId] and (aiRawDamage - lastAiRawDamageById[vehId]) or 0
      lastAiRawDamageById[vehId] = aiRawDamage

      if aiObj and playerPos then
        local dist = (playerPos - aiObj:getPosition()):length()
        if dist <= NO_CONTACT_DISTANCE_METERS then
          playerNearOpponent = true
          if aiDamageDelta > NO_CONTACT_DAMAGE_THRESHOLD then
            nearbyOpponentDamaged = true
          end
        end

        if dist <= NO_CONTACT_TOUCH_DISTANCE_METERS then
          local relSpeed = (playerVel - aiObj:getVelocity()):length()
          if relSpeed >= NO_CONTACT_TOUCH_REL_SPEED_MPS then
            touchedOpponent = true
          end
        end
      end
    end
  end

  return nearbyOpponentDamaged or touchedOpponent or (playerNearOpponent and playerDamageDelta > NO_CONTACT_DAMAGE_THRESHOLD)
end

local function updateNoContactTimer(dtSim)
  local timeout = getNoContactTimeoutSeconds()
  if timeout <= 0 then return false end

  if detectPlayerDerbyContact() then
    noContactTimer = 0
    derbyUi.clearNoContactWarning()
    return false
  end

  noContactTimer = noContactTimer + dtSim
  local timeLeft = timeout - noContactTimer
  local warningSeconds = math.min(getNoContactWarningSeconds(), timeout)
  if timeLeft <= warningSeconds and timeLeft > 0 then
    derbyUi.showNoContactWarning(timeLeft)
  end

  return noContactTimer >= timeout
end

function derbyDamageScoring.getActiveParticipantIds()
  local ids = {}
  if playerDerbyVehicleId and not playerEliminated then
    table.insert(ids, playerDerbyVehicleId)
  end
  for _, vehId in ipairs(spawnedAiIds) do
    if not eliminatedIds[vehId] then
      table.insert(ids, vehId)
    end
  end
  return ids
end

function derbyDamageScoring.reset()
  derbyDamageScoring.damageDealtById = {}
  derbyDamageScoring.lastRawDamageById = {}
  derbyDamageScoring.scoreDataById = {}
  for _, vehId in ipairs(derbyDamageScoring.getActiveParticipantIds()) do
    derbyDamageScoring.damageDealtById[vehId] = 0
    derbyDamageScoring.lastRawDamageById[vehId] = getRawVehicleDamage(vehId)
  end
end

function derbyDamageScoring.getNearestActiveAttackerId(damagedVehId, damagedPos)
  local bestId = nil
  local bestDist = DERBY_DAMAGE_ATTRIBUTION_RADIUS_METERS
  if not damagedPos then return nil end

  for _, candidateId in ipairs(derbyDamageScoring.getActiveParticipantIds()) do
    if candidateId ~= damagedVehId then
      local candidateObj = be:getObjectByID(candidateId)
      if candidateObj then
        local dist = (damagedPos - candidateObj:getPosition()):length()
        if dist <= bestDist then
          bestDist = dist
          bestId = candidateId
        end
      end
    end
  end

  return bestId
end

function derbyDamageScoring.update()
  for _, vehId in ipairs(derbyDamageScoring.getActiveParticipantIds()) do
    if derbyDamageScoring.damageDealtById[vehId] == nil then
      derbyDamageScoring.damageDealtById[vehId] = 0
    end

    local currentRawDamage = getRawVehicleDamage(vehId)
    local previousRawDamage = derbyDamageScoring.lastRawDamageById[vehId]
    derbyDamageScoring.lastRawDamageById[vehId] = currentRawDamage

    local delta = previousRawDamage and (currentRawDamage - previousRawDamage) or 0
    if delta > 0 then
      local damagedObj = be:getObjectByID(vehId)
      local attackerId = damagedObj and derbyDamageScoring.getNearestActiveAttackerId(vehId, damagedObj:getPosition()) or nil
      if attackerId then
        derbyDamageScoring.damageDealtById[attackerId] = (derbyDamageScoring.damageDealtById[attackerId] or 0) + delta
      end
    end
  end
end

function derbyDamageScoring.getParticipantData(vehId, damagePct)
  local healthScore = math.max(0, 100 - (tonumber(damagePct) or 0))
  if not vehId then
    return {
      healthScore = healthScore,
      damageDealt = 0,
      damageDealtScore = nil,
      derbyScore = nil,
    }
  end
  local data = derbyDamageScoring.scoreDataById[vehId] or {}
  return {
    healthScore = data.healthScore or healthScore,
    damageDealt = data.damageDealt or derbyDamageScoring.damageDealtById[vehId] or 0,
    damageDealtScore = data.damageDealtScore,
    derbyScore = data.derbyScore,
  }
end

function derbyDamageScoring.buildTimeoutSurvivorRow(vehId, isPlayer)
  local damagePct = getVehicleDamageNormalized(vehId, isPlayer == true)
  local scoring = derbyDamageScoring.getParticipantData(vehId, damagePct)
  return {
    id = vehId,
    isPlayer = isPlayer == true,
    damagePct = damagePct,
    healthScore = scoring.healthScore,
    damageDealt = scoring.damageDealt,
    damageDealtScore = 0,
    derbyScore = 0,
  }
end

function derbyDamageScoring.scoreTimeoutSurvivors(survivors)
  local maxDamageDealt = 0
  for _, row in ipairs(survivors) do
    maxDamageDealt = math.max(maxDamageDealt, tonumber(row.damageDealt) or 0)
  end

  for _, row in ipairs(survivors) do
    row.healthScore = math.max(0, 100 - (tonumber(row.damagePct) or 0))
    row.damageDealt = tonumber(row.damageDealt) or 0
    row.damageDealtScore = maxDamageDealt > 0 and ((row.damageDealt / maxDamageDealt) * 100) or 0
    if maxDamageDealt > 0 then
      row.derbyScore = (row.healthScore * DERBY_TIMEOUT_HEALTH_WEIGHT) + (row.damageDealtScore * DERBY_TIMEOUT_DAMAGE_DEALT_WEIGHT)
    else
      row.derbyScore = row.healthScore
    end
    derbyDamageScoring.scoreDataById[row.id] = {
      healthScore = row.healthScore,
      damageDealt = row.damageDealt,
      damageDealtScore = row.damageDealtScore,
      derbyScore = row.derbyScore,
    }
  end
end

local function getConfigTypeValues(info)
  if type(info) ~= "table" then return nil end
  local values = {}
  local seen = {}
  local rawValues = { info["Config Type"], info.ConfigType, info.configType, info["Derby Groups"], info.derbyGroups }
  if type(info.aggregates) == "table" then
    table.insert(rawValues, info.aggregates["Config Type"])
    table.insert(rawValues, info.aggregates.ConfigType)
    table.insert(rawValues, info.aggregates["Derby Groups"])
    table.insert(rawValues, info.aggregates.derbyGroups)
  end
  for _, raw in ipairs(rawValues) do
    if type(raw) == "string" and raw ~= "" and not seen[raw] then
      seen[raw] = true
      table.insert(values, raw)
    elseif type(raw) == "table" then
      for key, value in pairs(raw) do
        if type(key) == "string" and key ~= "" and value and not seen[key] then
          seen[key] = true
          table.insert(values, key)
        end
        if type(value) == "string" and value ~= "" and not seen[value] then
          seen[value] = true
          table.insert(values, value)
        end
      end
    end
  end
  return #values > 0 and values or nil
end

local function isDerbyConfigGroup(configType)
  return type(configType) == "string" and (configType == "ovalDerby" or configType:match("^rlsDerby%d*$") ~= nil)
end

local function getModelAndConfigFromInfoPath(infoPath)
  local normalized = tostring(infoPath or ""):gsub("\\", "/")
  local model, config = normalized:match("/?vehicles/([^/]+)/info_(.+)%.json$")
  if model and config and model ~= "" and config ~= "" then
    return model, config
  end
  return nil, nil
end

local function readVehicleInfoFile(infoPath)
  local path = tostring(infoPath or ""):gsub("\\", "/")
  local candidates = { path }
  local relativePath = path:match("(vehicles/.+)$")
  if relativePath and relativePath ~= path then
    table.insert(candidates, relativePath)
    table.insert(candidates, "/" .. relativePath)
  end
  if path:sub(1, 1) == "/" then
    table.insert(candidates, path:sub(2))
  else
    table.insert(candidates, "/" .. path)
  end

  for _, candidate in ipairs(candidates) do
    local ok, info = pcall(jsonReadFile, candidate)
    if ok and type(info) == "table" then
      return info
    end
  end
  return nil
end

local function fileLooksLikeDerbyInfo(infoPath)
  if not readFile then return true end
  local path = tostring(infoPath or ""):gsub("\\", "/")
  local candidates = { path }
  local relativePath = path:match("(vehicles/.+)$")
  if relativePath and relativePath ~= path then
    table.insert(candidates, relativePath)
    table.insert(candidates, "/" .. relativePath)
  end
  if path:sub(1, 1) == "/" then
    table.insert(candidates, path:sub(2))
  else
    table.insert(candidates, "/" .. path)
  end

  for _, candidate in ipairs(candidates) do
    local ok, content = pcall(readFile, candidate)
    if ok and type(content) == "string" then
      return content:find("rlsDerby", 1, true) ~= nil or content:find("ovalDerby", 1, true) ~= nil or content:find("Derby Groups", 1, true) ~= nil
    end
  end
  return true
end

local function addDerbyConfigToCache(cache, configTypes, model, config, label)
  if type(configTypes) ~= "table" or type(model) ~= "string" or model == "" or type(config) ~= "string" or config == "" then
    return
  end
  for _, configType in ipairs(configTypes) do
    if isDerbyConfigGroup(configType) then
      cache[configType] = cache[configType] or {}
      table.insert(cache[configType], {
        model = model,
        config = config,
        label = label or config
      })
    end
  end
end

local function addCoreVehicleDerbyConfigs(cache)
  if not core_vehicles or not core_vehicles.getModelList or not core_vehicles.getModel then
    return 0
  end

  local added = 0
  local modelList = core_vehicles.getModelList() or {}
  local models = modelList.models or {}
  for modelKey, _ in pairs(models) do
    if type(modelKey) == "string" and modelKey ~= "" then
      local modelData = core_vehicles.getModel(modelKey)
      local configs = modelData and modelData.configs
      if type(configs) == "table" then
        for configKey, configInfo in pairs(configs) do
          if type(configKey) == "string" and type(configInfo) == "table" then
            local configTypes = getConfigTypeValues(configInfo)
            if configTypes then
              addDerbyConfigToCache(cache, configTypes, modelKey, configKey, configInfo.Configuration or configInfo.Name or configKey)
              added = added + 1
            end
          end
        end
      end
    end
  end
  return added
end

local function addConfigListGeneratorDerbyConfigs(cache)
  if not util_configListGenerator or not util_configListGenerator.getEligibleVehicles then
    return 0
  end

  local ok, eligible = pcall(util_configListGenerator.getEligibleVehicles, false, false)
  if not ok or type(eligible) ~= "table" then
    return 0
  end

  local added = 0
  for _, info in ipairs(eligible) do
    if type(info) == "table" and type(info.model_key) == "string" and type(info.key) == "string" then
      local configTypes = getConfigTypeValues(info)
      if configTypes then
        addDerbyConfigToCache(cache, configTypes, info.model_key, info.key, info.Configuration or info.Name or info.key)
        added = added + 1
      end
    end
  end
  return added
end

local function addFileScannedDerbyConfigs(cache)
  if not FS then
    return 0
  end

  local added = 0
  local files = {}
  for _, root in ipairs({ "vehicles/", "/vehicles/", "vehicles", "/vehicles" }) do
    local ok, found = pcall(function()
      return FS:findFiles(root, "info_*.json", -1, true, false)
    end)
    if ok and type(found) == "table" then
      for _, path in ipairs(found) do
        files[path] = true
      end
    end
  end

  for infoPath, _ in pairs(files) do
    if fileLooksLikeDerbyInfo(infoPath) then
      local info = readVehicleInfoFile(infoPath)
      local configTypes = getConfigTypeValues(info)
      if configTypes then
        local model, config = getModelAndConfigFromInfoPath(infoPath)
        if model and config then
          addDerbyConfigToCache(cache, configTypes, model, config, info.Configuration or config)
          added = added + 1
        end
      end
    end
  end
  return added
end

local function buildDerbyConfigTypePoolCache()
  local cache = {}

  addCoreVehicleDerbyConfigs(cache)
  addConfigListGeneratorDerbyConfigs(cache)
  addFileScannedDerbyConfigs(cache)

  for _, pool in pairs(cache) do
    table.sort(pool, function(a, b)
      if a.model == b.model then
        return tostring(a.config) < tostring(b.config)
      end
      return tostring(a.model) < tostring(b.model)
    end)
  end

  return cache
end

local function getDerbyConfigTypePool(poolKey)
  if not poolKey then return nil end
  derbyConfigTypePoolCache = derbyConfigTypePoolCache or buildDerbyConfigTypePoolCache()
  local pool = derbyConfigTypePoolCache[poolKey]
  if type(pool) ~= "table" or #pool <= 0 then
    local lowerKey = tostring(poolKey):lower()
    for key, candidate in pairs(derbyConfigTypePoolCache) do
      if tostring(key):lower() == lowerKey then
        pool = candidate
        break
      end
    end
  end
  if type(pool) == "table" and #pool > 0 then
    return pool
  end
  return nil
end

local function getVehiclePoolEntryKey(entry)
  if type(entry) == "table" then
    return tostring(entry.model or entry[1] or "") .. "|" .. tostring(entry.config or entry.partConfig or "")
  end
  return tostring(entry) .. "|"
end

local function vehiclePoolEntryHasConfig(entry)
  return type(entry) == "table" and (entry.config or entry.partConfig) ~= nil
end

local function appendVehiclePoolEntries(target, seen, pool, requireConfig)
  if type(pool) ~= "table" then return end
  for _, entry in ipairs(pool) do
    if requireConfig and not vehiclePoolEntryHasConfig(entry) then
      _log("W", "Skipping model-only derby pool entry for strict pool: " .. tostring(type(entry) == "table" and (entry.model or entry[1]) or entry))
    else
      local key = getVehiclePoolEntryKey(entry)
      if key ~= "|" and not seen[key] then
        seen[key] = true
        table.insert(target, entry)
      end
    end
  end
end

local function countConfiguredVehiclePool(poolKey, cfg)
  if not poolKey then return 0 end

  local mergedPool = {}
  local seen = {}
  local pools = cfg and cfg.vehiclePools

  appendVehiclePoolEntries(mergedPool, seen, getDerbyConfigTypePool(poolKey), true)
  if type(pools) == "table" and type(pools[poolKey]) == "table" and #pools[poolKey] > 0 then
    appendVehiclePoolEntries(mergedPool, seen, pools[poolKey], true)
  end
  return #mergedPool
end

local function getConfiguredVehiclePool(poolKey)
  local mergedPool = {}
  local seen = {}
  local pools = activeEventCfg and activeEventCfg.vehiclePools

  appendVehiclePoolEntries(mergedPool, seen, getDerbyConfigTypePool(poolKey), true)
  if poolKey and type(pools) == "table" and type(pools[poolKey]) == "table" and #pools[poolKey] > 0 then
    appendVehiclePoolEntries(mergedPool, seen, pools[poolKey], true)
  end
  if #mergedPool > 0 then
    return mergedPool
  end

  if poolKey then
    _log("W", "No configured derby vehicle configs found for strict pool: " .. tostring(poolKey))
    return {}
  end

  if activeEventCfg and type(activeEventCfg.vehiclePool) == "table" and #activeEventCfg.vehiclePool > 0 then
    return activeEventCfg.vehiclePool
  end
  return { "etk800", "sunburst2", "bx", "covet", "pessima", "fullsize", "vivace" }
end

local function normalizeVehiclePoolEntry(entry)
  if type(entry) == "table" then
    return {
      model = entry.model or entry[1],
      config = entry.config or entry.partConfig,
      label = entry.label
    }
  end
  return { model = tostring(entry) }
end

local function pickRandomColor()
  local palette = {
    "0.9 0.1 0.1 1",   "0.1 0.2 0.7 1",   "0.95 0.75 0.05 1",
    "0.1 0.65 0.2 1",   "0.6 0.1 0.6 1",   "0.0 0.0 0.0 1",
    "0.85 0.4 0.0 1",   "0.2 0.8 0.9 1",   "0.9 0.9 0.9 1",
    "0.4 0.25 0.1 1",
  }
  return palette[math.random(1, #palette)]
end

-- ── zone debug visualization ───────────────────────────────────────────────
local function drawZoneOutline(zone, colorI, heightOffset)
  if not zone or not zone.vertices or #zone.vertices < 3 then return end
  local verts = zone.vertices
  local ho = heightOffset or 1.0
  for i = 1, #verts do
    local j = (i % #verts) + 1
    local p1 = vec3(verts[i][1], verts[i][2], verts[i][3] + ho)
    local p2 = vec3(verts[j][1], verts[j][2], verts[j][3] + ho)
    debugDrawer:drawLineInstance(p1, p2, 4, ColorI(colorI[1], colorI[2], colorI[3], colorI[4]))
  end
end

local function ensureForcedZoneDebugSpatialData()
  if not forceZoneDebugDraw then return end

  if not configData then
    configData = loadConfigData()
  end
  if not configData then
    return
  end

  if not sitesData then
    sitesData = loadSitesData(configData.sitesFile)
  end
  if not sitesData then
    return
  end

  local targetEventKey = forceZoneDebugEventKey or activeEvent or derbyUi.getActiveStagingEventKey()
  local targetCfg = targetEventKey and getEventConfig(targetEventKey) or nil

  if not targetCfg then
    local keys = getAvailableEventKeys()
    if #keys > 0 then
      targetEventKey = keys[1]
      targetCfg = getEventConfig(targetEventKey)
    end
  end

  if not targetCfg then
    return
  end

  if forceZoneDebugResolvedKey ~= targetEventKey or not resolvedPlayZone or not resolvedElimZones then
    resolveAllSpatialData(targetCfg)
    forceZoneDebugResolvedKey = targetEventKey
  end
end

local function drawDebugZones()
  if forceZoneDebugDraw then
    ensureForcedZoneDebugSpatialData()
  end
  if not drawZonesActive and not forceZoneDebugDraw then return end
  if not debugDrawer then return end

  -- Play zone: subtle teal
  if resolvedPlayZone then
    drawZoneOutline(resolvedPlayZone, { 0, 200, 180, 120 }, 1.0)
  end

  -- Elimination zones: semi-transparent red-orange
  if resolvedElimZones then
    for _, zone in ipairs(resolvedElimZones) do
      drawZoneOutline(zone, { 255, 80, 40, 140 }, 1.0)
    end
  end
end

-- UI bridge ──────────────────────────────────────────────────────────────

local function isAnotherActivityActive()
  if gameplay_events_freeroam_utils and type(gameplay_events_freeroam_utils.isExternalActivityBlockingFreeroam) == "function" then
    if gameplay_events_freeroam_utils.isExternalActivityBlockingFreeroam() then
      return true
    end
  end

  -- Checks if ANY other freeroam race is running
  if gameplay_events_freeroamEvents and type(gameplay_events_freeroamEvents.getFreeroamDisplayRaceLabel) == "function" then
    -- We must pcall the external function because freeroamEvents can crash (throw nil exceptions) if its internal states aren't initialized yet
    local success, currentRace = pcall(gameplay_events_freeroamEvents.getFreeroamDisplayRaceLabel)
    if success and currentRace and currentRace ~= "" then return true end
  end

  return false
end

local function isPlayerWalkingMode()
  return gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false
end

local function getPlayerStagingReferencePos()
  if isPlayerWalkingMode() and gameplay_walk and gameplay_walk.getPosXYZ then
    local wx, wy, wz = gameplay_walk.getPosXYZ()
    if wx and wy and wz then
      return vec3(wx, wy, wz)
    end

    local walkPos = wx
    if walkPos and type(walkPos) == "table" then
      if walkPos.x and walkPos.y and walkPos.z then
        return vec3(walkPos.x, walkPos.y, walkPos.z)
      end
      if walkPos[1] and walkPos[2] and walkPos[3] then
        return vec3(walkPos[1], walkPos[2], walkPos[3])
      end
    end
  end

  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh = playerVehId and be:getObjectByID(playerVehId) or nil
  if playerVeh then
    return playerVeh:getPosition()
  end

  return nil
end

local function getCurrentInventoryVehicleId()
  local playerVehId = be and be:getPlayerVehicleID(0) or nil
  if not playerVehId or not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
    return nil
  end
  return career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
end

local function getInventoryTableEntry(tbl, inventoryId)
  if type(tbl) ~= "table" or inventoryId == nil then return nil end
  return tbl[inventoryId] or tbl[tostring(inventoryId)] or tbl[tonumber(inventoryId)]
end

local function isInventoryVehicleInsured(inventoryId)
  if not inventoryId then
    return false
  end

  if career_modules_inventory and career_modules_inventory.getVehicles then
    local vehicles = career_modules_inventory.getVehicles() or {}
    local invVeh = getInventoryTableEntry(vehicles, inventoryId)
    local insuranceId = invVeh and tonumber(invVeh.insuranceId)
    if insuranceId and insuranceId > 0 then
      return true
    end
  end

  if career_modules_insurance_insurance then
    if career_modules_insurance_insurance.getInvVehs then
      local invVehs = career_modules_insurance_insurance.getInvVehs() or {}
      local invVeh = getInventoryTableEntry(invVehs, inventoryId)
      local insuranceId = invVeh and tonumber(invVeh.insuranceId)
      if insuranceId and insuranceId > 0 then
        return true
      end
    end

    if career_modules_insurance_insurance.getVehInsuranceInfo then
      local ok, info = pcall(career_modules_insurance_insurance.getVehInsuranceInfo, inventoryId)
      if ok and type(info) == "table" then
        local insuranceId = tonumber(info.insuranceId)
        if insuranceId and insuranceId > 0 then
          return true
        end
        if type(info.insuranceInfo) == "table" and tonumber(info.insuranceInfo.id) and tonumber(info.insuranceInfo.id) > 0 then
          return true
        end
      end
    end
  end

  return false
end

local function getStagingStartAvailability(maxAi, modeKey)
  local availableAiSlots = tonumber(maxAi)
  if availableAiSlots == nil then
    availableAiSlots = resolvedSpots and math.max(#resolvedSpots - 1, 0) or 0
  end
  if availableAiSlots < 1 then
    return false, "No parking spots available for AI opponents."
  end

  local stagingKey = derbyUi.getActiveStagingEventKey()
  local cfgForMode = activeEventCfg or (stagingKey and getEventConfig(stagingKey)) or nil
  local _, mode = getEntryModeConfig(cfgForMode, modeKey)
  local isLoanerMode = mode and mode.loaner == true
  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh = playerVehId and be:getObjectByID(playerVehId) or nil
  local aiPoolKey = mode and mode.aiPool
  if aiPoolKey and countConfiguredVehiclePool(aiPoolKey, cfgForMode) <= 0 then
    return false, "No derby vehicle configs found for " .. tostring(aiPoolKey) .. "."
  end
  local playerPoolKey = isLoanerMode and mode and mode.playerPool or nil
  if playerPoolKey and countConfiguredVehiclePool(playerPoolKey, cfgForMode) <= 0 then
    return false, "No loaner derby vehicle configs found for " .. tostring(playerPoolKey) .. "."
  end

  if not isLoanerMode then
    if isPlayerWalkingMode() or not playerVeh then
      return false, "You must be in a vehicle."
    end
    if freeroamUtils and freeroamUtils.isCarJockeyVehicle and freeroamUtils.isCarJockeyVehicle(playerVehId) then
      return false, "Car Jockey vehicles cannot be used for events."
    end
  end

  if mode and mode.requireUninsured == true then
    local invId = getCurrentInventoryVehicleId()
    if not invId then
      return false, "Derby requires a career-owned vehicle."
    end
    if isInventoryVehicleInsured(invId) then
      return false, "Derby requires an uninsured vehicle."
    end
  end

  if getDerbyEconomyMultiplier(cfgForMode) == 0 then
    return false, "Demolition Derby is disabled (demo multiplier set to 0)."
  end

  if career_challengeModes and career_challengeModes.isChallengeActive and career_challengeModes.isChallengeActive() then
    local activeChallenge = career_challengeModes.getActiveChallenge and career_challengeModes.getActiveChallenge()
    if activeChallenge and activeChallenge.economyAdjuster and activeChallenge.economyAdjuster.demo == 0 then
      return false, string.format("Demolition Derby is disabled due to '%s' Challenge.",
        activeChallenge.name or "Unknown")
    end
  end

  local fee = tonumber(mode and mode.entryFee) or 0
  if fee > 0 and career_modules_payment and career_modules_payment.canPay then
    if not career_modules_payment.canPay({ money = { amount = fee, canBeNegative = false } }) then
      return false, "Not enough money for the entry fee."
    end
  end

  return true, nil
end

local function ensureConfigAndSites()
  return refreshDerbyForCurrentLevel()
end

local function getDerbyEventSnapshot()
  return {
    eventActive = eventActive,
    activeEventCfg = activeEventCfg,
    playerDerbyVehicleId = playerDerbyVehicleId,
    spawnedAiIds = spawnedAiIds,
    spawnedAiInfo = spawnedAiInfo,
    eliminatedIds = eliminatedIds,
    playerEliminated = playerEliminated,
    playerPlacement = playerPlacement,
    eventFinishReason = eventFinishReason,
    activeEntryModeKey = activeEntryModeKey,
    activeEntryModeCfg = activeEntryModeCfg,
    totalParticipants = totalParticipants,
    lastRewardSummary = lastRewardSummary,
    activeWinnerRepairInsurance = activeWinnerRepairInsurance,
  }
end

derbyUi.setDeps({
  getEventConfig = getEventConfig,
  saveCareerProgress = saveCareerProgress,
  resolveAllSpatialData = resolveAllSpatialData,
  getStagingStartAvailability = getStagingStartAvailability,
  buildModeOptions = buildModeOptions,
  buildWinnerRepairInsurancePayload = buildWinnerRepairInsurancePayload,
  getResolvedSpots = function() return resolvedSpots end,
  setActiveEntryModeKey = function(modeKey) activeEntryModeKey = modeKey end,
  getActiveEntryModeKey = function() return activeEntryModeKey end,
  ensureConfigAndSites = ensureConfigAndSites,
  getAvailableEventKeys = getAvailableEventKeys,
  resolveParkingSpotByName = resolveParkingSpotByName,
  getPlayerStagingReferencePos = getPlayerStagingReferencePos,
  getFlowState = function()
    return {
      eventActive = eventActive,
      eventPhase = eventPhase,
      isAnotherActivityActive = isAnotherActivityActive(),
    }
  end,
  onStagingTeardownSpatial = function()
    drawZonesActive = false
    clearSpatialData()
  end,
  getEventSnapshot = getDerbyEventSnapshot,
  ordinal = ordinal,
  getVehicleDamageNormalized = getVehicleDamageNormalized,
  getDerbyDamageScoring = function() return derbyDamageScoring end,
  getElapsedEventTime = getElapsedEventTime,
})

function M.refreshStagingAvailability(modeKey, aiCount, winnerRepairInsurance)
  derbyUi.refreshStagingAvailability(modeKey, aiCount, winnerRepairInsurance)
end

local function teleportVehicleSafe(veh, pos, rot)
  if not veh or not pos or not rot then
    return false
  end
  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, nil, false)
  else
    veh:setPosRot(pos.x, pos.y, pos.z + 0.5, rot.x, rot.y, rot.z, rot.w)
  end
  return true
end

local function setVehicleStopped(vehId, destroyed)
  local obj = vehId and be:getObjectByID(vehId) or nil
  if not obj then return end
  obj:queueLuaCommand("if ai then ai.setMode('stop') end")
  obj:queueLuaCommand("input.event('throttle', 0, 1)")
  obj:queueLuaCommand("input.event('brake', 1, 1)")
  obj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
  if destroyed then
    obj:queueLuaCommand("electrics.setIgnitionLevel(0)")
    obj:queueLuaCommand("if fire and fire.explodeVehicle then fire.explodeVehicle() elseif fire and fire.igniteVehicle then fire.igniteVehicle() end")
  end
end

local function setPlayerFreeze(freeze)
  local aiRacers = gameplay_events_freeroam_aiRacers
  if aiRacers and aiRacers.setPlayerFreeze then
    pcall(function() aiRacers.setPlayerFreeze(freeze == true) end)
    return
  end
  local veh = be and be:getPlayerVehicle(0)
  if veh and core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function() core_vehicleBridge.executeAction(veh, "setFreeze", freeze == true) end)
  end
end

local function capturePlayerStagingTransform(veh)
  if not veh then
    return false
  end
  stagedPlayerTransform = {
    vehicleId = veh:getID(),
    pos = vec3(veh:getPosition()),
    rot = quat(veh:getRotation()),
  }
  return true
end

local function restorePlayerToStagingTransform()
  if not stagedPlayerTransform then
    return
  end

  local restoreVeh = nil
  if playerDerbyVehicleId then
    restoreVeh = be:getObjectByID(playerDerbyVehicleId)
  end
  if not restoreVeh then
    local currentPlayerVehId = be:getPlayerVehicleID(0)
    if currentPlayerVehId then
      restoreVeh = be:getObjectByID(currentPlayerVehId)
    end
  end
  if not restoreVeh and stagedPlayerTransform.vehicleId then
    restoreVeh = be:getObjectByID(stagedPlayerTransform.vehicleId)
  end

  if restoreVeh then
    teleportVehicleSafe(restoreVeh, stagedPlayerTransform.pos, stagedPlayerTransform.rot)
    pcall(function() be:enterVehicle(0, restoreVeh) end)
    if core_camera and core_camera.resetCamera then
      pcall(function() core_camera.resetCamera(0) end)
    end
  end

  stagedPlayerTransform = nil
end

local function restoreOriginalPlayerVehicle()
  if playerLoanerVehicleId then
    local loaner = be:getObjectByID(playerLoanerVehicleId)
    if loaner then loaner:delete() end
    playerLoanerVehicleId = nil
  end

  local restoreVeh = originalPlayerVehicleId and be:getObjectByID(originalPlayerVehicleId) or nil
  if restoreVeh and stagedPlayerTransform then
    teleportVehicleSafe(restoreVeh, stagedPlayerTransform.pos, stagedPlayerTransform.rot)
    pcall(function() be:enterVehicle(0, restoreVeh) end)
    if core_camera and core_camera.resetCamera then
      pcall(function() core_camera.resetCamera(0) end)
    end
  elseif restoreVeh then
    pcall(function() be:enterVehicle(0, restoreVeh) end)
  end
  stagedPlayerTransform = nil
end

local function spawnAi(requestedCount, reservedSpotIndex)
  if not resolvedSpots or #resolvedSpots == 0 then return 0 end
  local poolKey = activeEntryModeCfg and activeEntryModeCfg.aiPool or activeEventCfg and activeEventCfg.aiPool
  local pool  = getConfiguredVehiclePool(poolKey)
  local spawned = 0

  for i = 1, #resolvedSpots do
    if i ~= reservedSpotIndex then
      local spot = resolvedSpots[i]
      if spot and spot.pos and spot.rot then
        local spec = normalizeVehiclePoolEntry(pool[((i - 1) % #pool) + 1])
        local modelKey = spec.model
        local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
        local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
        local spawnOptions = {
          pos = pos,
          rot = rot,
          autoEnterVehicle = false,
        }
        if spec.config then
          spawnOptions.config = spec.config
        end
        local ok, veh = pcall(function()
          return core_vehicles.spawnNewVehicle(modelKey, spawnOptions)
        end)
        if ok and veh and veh.getID then
          local vehId = veh:getID()
          local personalityName = pickAiPersonalityName()
          local personality = getAiPersonalityProfiles()[personalityName] or DEFAULT_AI_PERSONALITIES.opportunist
          local reverseChance = clamp(tonumber(personality.preferReverseChance) or 0.35, 0, 1)
          table.insert(spawnedAiIds, vehId)
          spawnedAiInfo[vehId] = {
            model = modelKey,
            config = spec.config,
            index = spawned + 1,
            combatState = "idle",
            activeMode = "stop",
            stuckTimer = 0,
            stationaryTimer = 0,
            targetId = nil,
            personalityName = personalityName,
            retargetTimer = 0,
            retargetInterval = 0,
            driveMode = (math.random() < reverseChance and "demoderby_reverse" or "demoderby")
          }
          spawned = spawned + 1

          if extensions.core_vehicle_colors and extensions.core_vehicle_colors.setVehicleColor then
            pcall(function()
              extensions.core_vehicle_colors.setVehicleColor(0, pickRandomColor(), vehId)
            end)
          end

          -- Initial state: AI loaded, parked, engine starting. Chase activation happens after delay.
          local vehObj = be:getObjectByID(vehId)
          if vehObj then
            -- 0.39 leaves non-inventory event vehicles on stock ai.lua. The custom
            -- derby modes only exist in overrideAI, so install it explicitly before
            -- sending any mode commands to this vehicle.
            if overhaul_extensionManager and overhaul_extensionManager.applyOverrideAI then
              overhaul_extensionManager.applyOverrideAI(vehId)
            else
              vehObj:queueLuaCommand("extensions.load('overrideAI'); if overrideAI then ai = overrideAI end")
            end
            vehObj:queueLuaCommand("ai.setMode('stop')")
            vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
            local shouldStartEngine = activeEventCfg and activeEventCfg.startEngineOnSpawn
            if shouldStartEngine ~= false then
              vehObj:queueLuaCommand("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end; if controller.mainController then controller.mainController.setStarter(true) end")
            end
          end
        else
          _log("W", "Failed to spawn AI at spot " .. tostring(i) .. ": " .. tostring(veh))
        end

        if spawned >= requestedCount then
          break
        end
      end
    end
  end
  return spawned
end

-- ── AI behavior activation & retargeting ───────────────────────────────────

local function getAliveAiIds()
  local alive = {}
  for _, id in ipairs(spawnedAiIds) do
    if not eliminatedIds[id] then
      table.insert(alive, id)
    end
  end
  return alive
end

local function buildTargetCandidatesForAi(aiVehId, excludedId)
  local candidates = {}
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId ~= aiVehId and playerVehId ~= excludedId and not playerEliminated then
    table.insert(candidates, playerVehId)
  end
  for _, id in ipairs(getAliveAiIds()) do
    if id ~= aiVehId and id ~= excludedId then
      table.insert(candidates, id)
    end
  end
  return candidates
end

local function isValidTargetForAi(aiVehId, targetId)
  if not targetId or targetId == aiVehId or not be:getObjectByID(targetId) then return false end
  if targetId == be:getPlayerVehicleID(0) then return not playerEliminated end
  return not eliminatedIds[targetId] and spawnedAiInfo[targetId] ~= nil
end

local function pickNearestTargetForAi(aiVehId, excludedId)
  local aiObj = be:getObjectByID(aiVehId)
  if not aiObj then return nil end
  local aiPos = aiObj:getPosition()
  local bestId = nil
  local bestDist = math.huge
  for _, id in ipairs(buildTargetCandidatesForAi(aiVehId, excludedId)) do
    local obj = be:getObjectByID(id)
    if obj then
      local pos = obj:getPosition()
      if isInsidePlayZone(pos) then
        local dist = (aiPos - pos):squaredLength()
        if dist < bestDist then
          bestDist = dist
          bestId = id
        end
      end
    end
  end
  return bestId
end

local function pickTargetForAi(aiVehId, isFirstTarget, excludedId)
  local nearest = pickNearestTargetForAi(aiVehId, excludedId)
  if nearest and math.random() < 0.50 then
    return nearest
  end

  -- Decide: target the player or a random other AI?
  local playerWeight = (activeEventCfg and activeEventCfg.aiPlayerTargetWeight) or 0.4
  local personality = getAiPersonality(aiVehId)
  playerWeight = playerWeight + (tonumber(personality.playerTargetWeightBonus) or 0)
  playerWeight = clamp(playerWeight, 0, 1)
  if isFirstTarget then
    playerWeight = 0.25
  end
  local playerVehId  = be:getPlayerVehicleID(0)
  local playerEligible = playerVehId and playerVehId ~= aiVehId and playerVehId ~= excludedId and not playerEliminated
  local aliveAi      = getAliveAiIds()

  -- Build candidate list: other alive AI (not self)
  local otherAi = {}
  for _, id in ipairs(aliveAi) do
    if id ~= aiVehId and id ~= excludedId then
      table.insert(otherAi, id)
    end
  end

  if #otherAi == 0 then
    return playerEligible and playerVehId or nil
  end
  if not playerEligible then
    return otherAi[math.random(1, #otherAi)]
  end

  -- Weighted random: playerWeight chance to target player, rest targets random AI
  if math.random() < playerWeight then
    return playerVehId
  else
    return otherAi[math.random(1, #otherAi)]
  end
end

local function getSafestTargetId(aiVehId)
  local center = getPlayzoneCentroid()
  local bestId = nil
  local bestDist = math.huge
  
  local candidates = getAliveAiIds()
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and not playerEliminated then
    table.insert(candidates, playerVehId)
  end
  
  for _, id in ipairs(candidates) do
    if id ~= aiVehId then
      local obj = be:getObjectByID(id)
      if obj then
        local p = obj:getPosition()
        if isInsidePlayZone(p) then
          local dist = (p - center):length()
          if dist < bestDist then
            bestDist = dist
            bestId = id
          end
        end
      end
    end
  end
  
  -- Fallback to random if nobody is safe
  if not bestId then 
    return pickTargetForAi(aiVehId, false) 
  end
  return bestId
end

local function setAiChaseTarget(aiVehId, targetId)
  local vehObj = be:getObjectByID(aiVehId)
  if not vehObj or not targetId then return end
  local personality = getAiPersonality(aiVehId)
  local aggression = (activeEventCfg and activeEventCfg.aiAggression) or 1.2
  aggression = aggression * (tonumber(personality.aggressionMultiplier) or 1)
  aggression = math.max(1.6, aggression)
  local avoidCars  = (activeEventCfg and activeEventCfg.aiAvoidCars) or "off"
  
  local info = spawnedAiInfo[aiVehId]
  if info then
    local desiredMode = info.driveMode
    local modeChanged = info.activeMode ~= desiredMode
    info.targetId = targetId
    info.stuckTimer = 0
    info.combatState = desiredMode
    if modeChanged then
      vehObj:queueLuaCommand("ai.setMode('" .. desiredMode .. "')")
      info.activeMode = desiredMode
    end
    vehObj:queueLuaCommand("ai.setAvoidCars('" .. avoidCars .. "')")
  end
  
  vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(targetId) .. ")")
  vehObj:queueLuaCommand("ai.setAggression(" .. tostring(aggression) .. ")")
  vehObj:queueLuaCommand("ai.driveInLane('off')")
  vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
end

-- Called by the vehicle-side controller as soon as it starts an escape manoeuvre.
-- Prefer a different opponent so the car does not reverse and immediately push into
-- the same deadlock again. The mode is deliberately left untouched during recovery.
function M.onAiRecoveryRequest(aiVehId)
  if not eventActive or not aiActivated or eliminatedIds[aiVehId] then return end
  local info = spawnedAiInfo[aiVehId]
  local vehObj = be:getObjectByID(aiVehId)
  if not info or not vehObj then return end

  local previousTargetId = info.targetId
  local newTargetId = pickNearestTargetForAi(aiVehId, previousTargetId)
    or pickTargetForAi(aiVehId, false, previousTargetId)
    or pickTargetForAi(aiVehId, false)
  if newTargetId then
    info.targetId = newTargetId
    info.retargetTimer = 0
    info.retargetInterval = getAiRetargetInterval(aiVehId)
    info.stuckTimer = 0
    info.impactTimer = 0
    info.lastPos = vec3(vehObj:getPosition())
    vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(newTargetId) .. ")")
  end
end

local function activateAllAi()
  _log("I", "Activating AI chase behavior for " .. tostring(#spawnedAiIds) .. " vehicles")
  for _, vehId in ipairs(spawnedAiIds) do
    if not eliminatedIds[vehId] then
      local vehObj = be:getObjectByID(vehId)
      if vehObj then
        -- Release parking brake
        vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
      end
      local targetId = pickTargetForAi(vehId, true)
      setAiChaseTarget(vehId, targetId)
      local info = spawnedAiInfo[vehId]
      if info then
        info.retargetTimer = 0
        info.retargetInterval = getAiRetargetInterval(vehId)
      end
    end
  end
  aiActivated = true
end

local function clearAllAi()
  for _, id in ipairs(spawnedAiIds) do
    despawnVehicle(id)
  end
  spawnedAiIds = {}
  spawnedAiInfo = {}
  eliminatedIds = {}
  playerPlacement = nil
  totalParticipants = 0
  nextPlacement = 0
  eventElapsedTime = 0
  rewardsSettled = false
  lastRewardSummary = nil
  playerInventoryId = nil
  playerDerbyVehicleId = nil
  originalPlayerVehicleId = nil
  playerLoanerVehicleId = nil
  stagedPlayerTransform = nil
  firstAiEliminationElapsed = nil
  eventFinishReason = nil
  derbyUi.clearDerbyCountdownWarnings()
  derbyDamageScoring.damageDealtById = {}
  derbyDamageScoring.lastRawDamageById = {}
  derbyDamageScoring.scoreDataById = {}
  aiActivated = false
  aiActivationTimer = 0
  stagedAiCount = 0
  activeWinnerRepairInsurance = false
end

local function recordDerbyStats(playerWasEliminated, playerPlace)
  if not (career_career and career_career.isActive and career_career.isActive()) then
    return
  end
  if not (leaderboardManager and leaderboardManager.updateDemoDerbyStats) then
    return
  end

  local place = tonumber(playerPlace)
  if not place or place < 1 then
    place = math.max(1, totalParticipants)
  end

  local elapsed = getElapsedEventTime()
  local raceLabel = tostring((activeEventCfg and activeEventCfg.label) or activeEvent or "Demolition Derby")
  local inventoryId = playerInventoryId
  if not inventoryId then
    local currentVehId = be:getPlayerVehicleID(0)
    inventoryId = resolveSessionInventoryFromSpawnId(currentVehId)
  end
  if not inventoryId then
    return
  end

  leaderboardManager.updateDemoDerbyStats(inventoryId, raceLabel, {
    placement = place,
    eliminated = playerWasEliminated == true,
    survivalTime = elapsed,
    fastestEliminationTime = firstAiEliminationElapsed,
  })
end

local function payEntryFee(modeCfg)
  local fee = math.max(0, math.floor(tonumber(modeCfg and modeCfg.entryFee) or 0))
  if fee <= 0 then return true end
  if not (career_career and career_career.isActive and career_career.isActive()) then
    return true
  end
  if career_modules_payment and career_modules_payment.pay then
    return career_modules_payment.pay({ money = { amount = fee, canBeNegative = false } }, {
      label = "Demolition Derby Entry Fee",
      tags = { "gameplay", "fre", "demo", "entryFee" }
    })
  end
  return false
end

local function spawnPlayerLoaner(pos, rot)
  local poolKey = activeEntryModeCfg and activeEntryModeCfg.playerPool or "rlsDerby100"
  local pool = getConfiguredVehiclePool(poolKey)
  if not pool or #pool == 0 then return nil end
  local spec = normalizeVehiclePoolEntry(pool[math.random(1, #pool)])
  if not spec.model then return nil end
  local spawnOptions = { pos = pos, rot = rot, autoEnterVehicle = true }
  if spec.config then spawnOptions.config = spec.config end
  local ok, veh = pcall(function()
    return core_vehicles.spawnNewVehicle(spec.model, spawnOptions)
  end)
  if ok and veh and veh.getID then
    local vehId = veh:getID()
    playerLoanerVehicleId = vehId
    playerDerbyVehicleId = vehId
    setVehicleStopped(vehId, false)
    return vehId
  end
  _log("W", "Failed to spawn derby loaner: " .. tostring(veh))
  return nil
end

local function persistOwnCarDamage()
  if activeEntryModeCfg and activeEntryModeCfg.persistDamage == true and playerInventoryId and career_modules_damageManager and career_modules_damageManager.saveDamageState then
    pcall(function() career_modules_damageManager.saveDamageState(playerInventoryId) end)
  end
end

local function repairWinningOwnCar()
  if not activeWinnerRepairInsurance then
    return false
  end
  if not (activeEntryModeCfg and activeEntryModeCfg.persistDamage == true and playerInventoryId) then
    return false
  end
  if not (career_modules_inventory and career_modules_inventory.getVehicles and core_vehicleBridge) then
    return false
  end

  local vehicles = career_modules_inventory.getVehicles()
  local vehicleInfo = vehicles and vehicles[playerInventoryId]
  if not vehicleInfo then
    return false
  end

  local function finishRepair(partConditions)
    vehicleInfo.partConditions = partConditions or vehicleInfo.partConditions or {}

    if career_modules_insurance_insurance and career_modules_insurance_insurance.repairPartConditions then
      local ok = pcall(function() career_modules_insurance_insurance.repairPartConditions({
        partConditions = vehicleInfo.partConditions,
        paintRepair = true,
        inventoryId = playerInventoryId
      }) end)
      if not ok then
        for _, info in pairs(vehicleInfo.partConditions) do
          if type(info) == "table" then
            info.integrityValue = 1
            info.integrityState = nil
            info.visualValue = 1
            info.visualState = nil
          end
        end
      end
    else
      for _, info in pairs(vehicleInfo.partConditions) do
        if type(info) == "table" then
          info.integrityValue = 1
          info.integrityState = nil
          info.visualValue = 1
          info.visualState = nil
        end
      end
    end

    if career_modules_damageManager and career_modules_damageManager.clearDamageState then
      pcall(function() career_modules_damageManager.clearDamageState(playerInventoryId) end)
    end
    if career_modules_inventory.setVehicleDirty then
      pcall(function() career_modules_inventory.setVehicleDirty(playerInventoryId) end)
    end

    local didReload = false
    if career_modules_insurance_insurance and career_modules_insurance_insurance.startRepairInstant then
      local ok = pcall(function()
        career_modules_insurance_insurance.startRepairInstant(vehicleInfo, function()
          saveCareerProgress("winner repair")
        end, true)
      end)
      didReload = ok
    end

    if not didReload and career_modules_inventory.spawnVehicle then
      local ok = pcall(function()
        career_modules_inventory.spawnVehicle(playerInventoryId, 2, function()
          saveCareerProgress("winner repair")
        end)
      end)
      didReload = ok
    end

    if not didReload then
      local vehId = career_modules_inventory.getVehicleIdFromInventoryId and career_modules_inventory.getVehicleIdFromInventoryId(playerInventoryId) or playerDerbyVehicleId
      local vehObj = vehId and be:getObjectByID(vehId) or nil
      if vehObj and core_vehicleBridge.executeAction then
        core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehicleInfo.partConditions, 0, 1, 1)
      end
    end
  end

  local vehId = career_modules_inventory.getVehicleIdFromInventoryId and career_modules_inventory.getVehicleIdFromInventoryId(playerInventoryId) or playerDerbyVehicleId
  local vehObj = vehId and be:getObjectByID(vehId) or nil
  if vehObj and core_vehicleBridge.requestValue then
    core_vehicleBridge.requestValue(vehObj, function(res)
      finishRepair(res and res.result or vehicleInfo.partConditions)
    end, 'getPartConditions')
  else
    finishRepair(vehicleInfo.partConditions)
  end

  if ui_message then
    ui_message("Your car has been fully repaired.", 5, "demoWinnerRepair", "check")
  end
  return true
end

-- ── event lifecycle ────────────────────────────────────────────────────────
function M.startEvent(requestedAiCount, eventKey, modeKey, winnerRepairInsurance)
  if eventPhase ~= "idle" and eventPhase ~= "configure" then return end

  configData = loadConfigData()
  if not configData then
    _log("W", "Cannot start demo event – no config data.")
    return
  end

  local key = eventKey
  if not key or not configData.events or not configData.events[key] then
    local keys = getAvailableEventKeys()
    key = keys[1]
  end
  if not key then
    _log("W", "No demo events defined in config.")
    return
  end

  activeEvent    = key
  activeEventCfg = getEventConfig(key)
  if not activeEventCfg then
    _log("W", "Could not resolve config for event: " .. tostring(key))
    return
  end
  activeEntryModeKey, activeEntryModeCfg = getEntryModeConfig(activeEventCfg, modeKey or "loaner")
  activeWinnerRepairInsurance = winnerRepairInsurance == true
    and isWinnerRepairInsuranceAvailable(activeEventCfg, activeEntryModeKey)

  sitesData = loadSitesData(configData.sitesFile)
  if not sitesData then
    _log("W", "Cannot start demo event – no sites data.")
    return
  end

  resolveAllSpatialData(activeEventCfg)

  if not resolvedSpots or #resolvedSpots < 2 then
    _log("W", "Need at least 2 parking spots (player + AI).")
    return
  end
  if not resolvedElimZones or #resolvedElimZones == 0 then
    _log("W", "No elimination zones resolved for event: " .. tostring(key))
  end

  local playerVehId = be:getPlayerVehicleID(0)
  local playerVehObj = playerVehId and be:getObjectByID(playerVehId) or nil
  if not (activeEntryModeCfg and activeEntryModeCfg.loaner == true) and not playerVehObj then
    _log("W", "Cannot start demo event – no player vehicle.")
    return
  end

  local availableAiSpots = math.max(0, #resolvedSpots - 1)
  local maxAi = math.min(tonumber(activeEventCfg.maxOpponents) or 10, MAX_SELECTABLE_AI_OPPONENTS, availableAiSpots)
  if maxAi < 1 then
    _log("W", "No parking spots available for AI opponents.")
    return
  end
  local count = tonumber(requestedAiCount) or 6
  count = math.max(1, math.min(count, maxAi))

  local canStart, startDisabledReason = getStagingStartAvailability(maxAi, activeEntryModeKey)
  if not canStart then
    _log("I", "Demo derby start blocked: " .. tostring(startDisabledReason))
    derbyUi.emitDemoStagingUi({
      visible = true,
      phase = "configure",
      maxAi = maxAi,
      eventKey = key,
      label = activeEventCfg.label or "Demolition Derby",
      selectedMode = activeEntryModeKey,
      modeOptions = buildModeOptions(activeEventCfg, count),
      startEnabled = false,
      startDisabledReason = startDisabledReason
    })
    return
  end

  originalPlayerVehicleId = playerVehObj and playerVehId or nil
  playerInventoryId = getCurrentInventoryVehicleId()
  if playerVehObj then
    capturePlayerStagingTransform(playerVehObj)
  else
    stagedPlayerTransform = nil
  end

  local playerSpotIndex = math.random(1, #resolvedSpots)
  local playerSpot = resolvedSpots[playerSpotIndex]
  if not (playerSpot and playerSpot.pos and playerSpot.rot) then
    _log("W", "Invalid player spawn parking spot for event: " .. tostring(key))
    stagedPlayerTransform = nil
    return
  end

  derbyUi.hideStagingPopup()

  local playerSpawnPos = vec3(playerSpot.pos[1], playerSpot.pos[2], playerSpot.pos[3])
  local playerSpawnRot = quat(playerSpot.rot[1], playerSpot.rot[2], playerSpot.rot[3], playerSpot.rot[4])

  if activeEntryModeCfg and activeEntryModeCfg.loaner == true then
    if not spawnPlayerLoaner(playerSpawnPos, playerSpawnRot) then
      restoreOriginalPlayerVehicle()
      clearSpatialData()
      activeEvent = nil
      activeEventCfg = nil
      activeEntryModeCfg = nil
      eventPhase = "idle"
      return
    end
  else
    teleportVehicleSafe(playerVehObj, playerSpawnPos, playerSpawnRot)
    playerDerbyVehicleId = playerVehId
    setVehicleStopped(playerDerbyVehicleId, false)
  end

  if activeEventCfg.removeTraffic ~= false and gameplay_traffic then
    gameplay_traffic.setActiveAmount(0)
    trafficSuppressedForEvent = true
  else
    trafficSuppressedForEvent = false
  end

  local spawned = spawnAi(count, playerSpotIndex)
  if spawned < 1 then
    _log("W", "Demo derby start aborted: failed to spawn AI.")
    restoreOriginalPlayerVehicle()
    restoreTrafficAfterEvent()
    clearSpatialData()
    activeEvent = nil
    activeEventCfg = nil
    drawZonesActive = false
    return
  end

  if not payEntryFee(activeEntryModeCfg) then
    _log("I", "Demo derby start blocked: entry fee payment failed.")
    local failedLabel = activeEventCfg and activeEventCfg.label or "Demolition Derby"
    local failedOptions = buildModeOptions(activeEventCfg, count)
    restoreOriginalPlayerVehicle()
    clearAllAi()
    restoreTrafficAfterEvent()
    clearSpatialData()
    activeEvent = nil
    activeEventCfg = nil
    activeEntryModeCfg = nil
    activeEntryModeKey = "loaner"
    eventPhase = "idle"
    derbyUi.emitDemoStagingUi({
      visible = true,
      phase = "configure",
      maxAi = maxAi,
      eventKey = key,
      label = failedLabel,
      selectedMode = activeEntryModeKey,
      modeOptions = failedOptions,
      startEnabled = false,
      startDisabledReason = "Not enough money for the entry fee."
    })
    return
  end
  saveCareerProgress("entry fee payment")
  _log("I", "Demo derby '" .. tostring(key) .. "' staged with " .. tostring(spawned) .. " AI.")

  eventActive = false
  eventPhase = "gridStaged"
  showDerbyArenaBarriers()
  playerEliminated = false
  playerPlacement = nil
  totalParticipants = spawned + 1  -- AI + player
  nextPlacement = totalParticipants
  eventElapsedTime = 0
  rewardsSettled = false
  stationaryTimers = {}
  firstAiEliminationElapsed = nil
  stagedAiCount = spawned
  resetNoContactState()
  derbyDamageScoring.reset()

  -- Start AI activation countdown
  aiActivated = false
  aiActivationDelay = (activeEventCfg and activeEventCfg.aiActivationDelay) or 2.0
  aiActivationTimer = 0

  setPlayerFreeze(true)
  derbyUi.emitDemoStagingUi({
    visible = true,
    phase = "ready",
    maxAi = maxAi,
    aiCount = spawned,
    eventKey = key,
    label = activeEventCfg.label or "Demolition Derby",
    selectedMode = activeEntryModeKey,
    modeOptions = buildModeOptions(activeEventCfg, spawned),
    startEnabled = true,
    startDisabledReason = nil,
  })
end

function M.beginCountdown()
  if eventPhase ~= "gridStaged" then return false end
  eventPhase = "countdown"
  derbyUi.hideStagingPopup()
  setPlayerFreeze(true)
  derbyUi.resetScenarioFlash()

  core_jobsystem.create(function(job)
    derbyUi.triggerScenarioFlash({
      {3, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')", true},
      {2, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown2')", true},
      {1, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown3')", true},
    })
    job.sleep(3)
    if eventPhase ~= "countdown" then
      setPlayerFreeze(false)
      return
    end
    derbyUi.resetScenarioFlash()
    derbyUi.triggerScenarioFlash({
      {"ui.scenarios.go", 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')", true},
    })
    setPlayerFreeze(false)
    if playerDerbyVehicleId then
      local playerObj = be:getObjectByID(playerDerbyVehicleId)
      if playerObj then
        playerObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
        playerObj:queueLuaCommand("input.event('brake', 0, 1)")
        playerObj:queueLuaCommand("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end; if controller.mainController then controller.mainController.setStarter(true) end")
      end
    end
    eventElapsedTime = 0
    resetNoContactState()
    derbyDamageScoring.reset()
    eventActive = true
    eventPhase = "running"
    aiActivationTimer = 0
    activateAllAi()
    derbyUi.showDemoHud()
    derbyUi.pushDemoHudState()
  end)
  return true
end

function M.endEvent(playerWasEliminated, playerPlace, eliminationReason)
  if eventPhase ~= "running" then return end
  eventActive = false
  eventPhase = "results"
  drawZonesActive = false
  eventFinishReason = eliminationReason or "completed"
  derbyUi.clearDerbyCountdownWarnings()

  recordDerbyStats(playerWasEliminated, playerPlace)

  local rewardSummary = settleCareerRewards(playerWasEliminated, playerPlace, eliminationReason)

  local playerWon = tonumber(playerPlace) == 1 and playerWasEliminated ~= true
  local repairQueued = false
  if playerWon then
    repairQueued = repairWinningOwnCar()
    if not repairQueued then
      persistOwnCarDamage()
    end
  else
    persistOwnCarDamage()
  end
  if not repairQueued then
    saveCareerProgress("event finish")
  end

  derbyUi.hideDemoHud()
  derbyUi.showCongratulations(playerWasEliminated, playerPlace, eliminationReason, rewardSummary)
end

function M.cancelStaging()
  derbyUi.markStagingDismissed(derbyUi.getActiveStagingEventKey())
  derbyUi.hideStagingPopup()
  derbyUi.clearDerbyCountdownWarnings()
  derbyUi.hideDemoHud()
  if eventPhase == "gridStaged" or eventPhase == "countdown" then
    eventPhase = "cleanup"
    setPlayerFreeze(false)
    derbyUi.resetScenarioFlash()
    restoreOriginalPlayerVehicle()
    clearAllAi()
    restoreTrafficAfterEvent()
    activeEvent = nil
    activeEventCfg = nil
    activeEntryModeCfg = nil
    activeEntryModeKey = "loaner"
    activeWinnerRepairInsurance = false
    eventPhase = "idle"
  end
  drawZonesActive = false
  clearSpatialData()
  stagedPlayerTransform = nil
  activeWinnerRepairInsurance = false
  hideDerbyArenaBarriers()
end

function M.dismissCongratulations()
  derbyUi.hideCongratulations()
  if eventPhase == "results" then
    eventPhase = "cleanup"
    setPlayerFreeze(false)
    if activeEntryModeCfg and activeEntryModeCfg.loaner == true then
      restoreOriginalPlayerVehicle()
    else
      restorePlayerToStagingTransform()
    end
    clearAllAi()
    restoreTrafficAfterEvent()
    clearSpatialData()
    activeEvent = nil
    activeEventCfg = nil
    activeEntryModeCfg = nil
    activeEntryModeKey = "loaner"
    activeWinnerRepairInsurance = false
    eventPhase = "idle"
    saveCareerProgress("post-event cleanup")
  end
  hideDerbyArenaBarriers()
end

local function setZoneDebugDrawOverride(enabled, eventKey)
  forceZoneDebugDraw = enabled == true
  forceZoneDebugResolvedKey = nil

  if forceZoneDebugDraw then
    if type(eventKey) == "string" and eventKey ~= "" then
      forceZoneDebugEventKey = eventKey
    end
  else
    forceZoneDebugEventKey = nil
    if not drawZonesActive and not eventActive and not derbyUi.isStagingShown() then
      clearSpatialData()
    end
  end

  _log("I", "Zone debug draw " .. (forceZoneDebugDraw and "enabled" or "disabled") ..
    (forceZoneDebugEventKey and (" for " .. forceZoneDebugEventKey) or ""))

  return forceZoneDebugDraw
end

function M.setZoneDebugDrawEnabled(enabled, eventKey)
  local parsed = parseConsoleBool(enabled)
  if parsed == nil then
    _log("W", "setZoneDebugDrawEnabled expects true/false, on/off, or 1/0")
    return forceZoneDebugDraw
  end
  return setZoneDebugDrawOverride(parsed, eventKey)
end

function M.toggleZoneDebugDraw(eventKey)
  return setZoneDebugDrawOverride(not forceZoneDebugDraw, eventKey)
end

function M.getZoneDebugDrawState()
  return {
    enabled = forceZoneDebugDraw,
    eventKey = forceZoneDebugEventKey,
    activeEvent = activeEvent,
    stagingEventKey = derbyUi.getActiveStagingEventKey()
  }
end

M.setDebugZonesEnabled = M.setZoneDebugDrawEnabled
M.toggleDebugZones = M.toggleZoneDebugDraw

function M.isRecoveryRadialOverrideActive()
  return eventPhase == "gridStaged"
      or eventPhase == "countdown"
      or eventPhase == "running"
      or eventPhase == "results"
end

function M.ownsRaceHud()
  return eventActive == true and eventPhase == "running"
end

-- --- Derby flip unstuck (disabled)
--[[
function M.isDerbyRecoveryUnstuckAvailable()
  return eventPhase == "gridStaged"
      or eventPhase == "countdown"
      or eventPhase == "running"
end

function M.radialUnstuckPlayerVehicle()
  if not M.isDerbyRecoveryUnstuckAvailable() then
    return false, "No active derby event."
  end

  if activeEventCfg and not resolvedPlayZone then
    resolveAllSpatialData(activeEventCfg)
  end

  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh = playerVehId and be:getObjectByID(playerVehId) or nil
  if not playerVeh then
    return false, "No player vehicle."
  end

  local currentSpeed = playerVeh:getVelocity():length()
  if currentSpeed > RADIAL_UNSTUCK_MAX_SPEED_MPS then
    return false, string.format("Slow below %.0f km/h to use unstuck.", RADIAL_UNSTUCK_MAX_SPEED_KMH)
  end

  local currentPos = playerVeh:getPosition()
  local currentRot = quat(playerVeh:getRotation())
  local targetPos = pickUnstuckPointInsidePlayZone(currentPos, playerVehId)
  targetPos = targetPos and findNearestFreeUnstuckPoint(targetPos, currentPos.z, playerVehId) or nil
  if not targetPos then
    return false, "No free unstuck point inside play zone."
  end

  local finalPos = vec3(targetPos.x, targetPos.y, targetPos.z + 0.25)

  local refNodeId = playerVeh:getRefNodeId()
  if refNodeId and playerVeh.setClusterPosRelRot then
    playerVeh:setClusterPosRelRot(refNodeId, finalPos.x, finalPos.y, finalPos.z, 0, 0, 0, 1)
    if playerVeh.applyClusterVelocityScaleAdd then
      playerVeh:applyClusterVelocityScaleAdd(refNodeId, 0, 0, 0, 0)
    end
  else
    playerVeh:setPosRot(finalPos.x, finalPos.y, finalPos.z, currentRot.x, currentRot.y, currentRot.z, currentRot.w)
  end

  if ui_message then
    ui_message("Unstuck: moved inside derby play area.", 3, "demoUnstuck")
  end

  return true
end
]]

-- ── trigger handling (called from freeroamEvents) ──────────────────────────
function M.onStagingTrigger(_, event, demoEventKey)
  if not demoEventKey or demoEventKey == "" then
    return
  end
  if event == "enter" then
    derbyUi.handleMarkerStagingEnter(demoEventKey, {
      eventActive = eventActive,
      isAnotherActivityActive = isAnotherActivityActive(),
      ensureConfigLoaded = function()
        return ensureConfigAndSites()
      end,
    })
  elseif event == "exit" then
    derbyUi.onMarkerStagingExit(demoEventKey)
  end
end

function M.dismissDemoIntro(dontShowAgain, eventKey)
  eventKey = eventKey or derbyUi.getActiveStagingEventKey()
  if not eventKey then
    return
  end
  derbyUi.dismissIntroAndShowConfigure(dontShowAgain, eventKey)
end

function M.onCareerModulesActivated()
  derbyUi.onCareerModulesActivated()
end

-- ── per-frame update ───────────────────────────────────────────────────────
local hudPushAccum = 0
local HUD_PUSH_INTERVAL = 0.25  -- push HUD state 4x/sec, not every frame

function M.onUpdate(dtReal, dtSim, dtRaw)
  -- freeroamEvents manually ticks this controller with one argument. Treat that as
  -- the authoritative update path so markers/staging still work when this child
  -- extension is not ticked directly by the engine. Ignore automatic engine ticks
  -- to keep timers from advancing twice per frame.
  if dtSim ~= nil then return end
  dtSim = tonumber(dtReal) or 0
  dtReal = dtSim

  -- Always draw debug zones when active (immediate mode, must draw every frame)
  drawDebugZones()

  if eventPhase ~= "running" then
    if not refreshDerbyForCurrentLevel() then
      return
    end
    if eventPhase == "idle" or eventPhase == "configure" then
      derbyUi.updateStagingPopupFromStartSpots()
    end
    return
  end

  derbyDamageScoring.update()

  eventElapsedTime = eventElapsedTime + dtSim

  local timeLimit = tonumber(activeEventCfg and activeEventCfg.timeLimitSeconds) or 300
  if timeLimit > 0 and getElapsedEventTime() >= timeLimit then
    local survivors = {}
    if not playerEliminated then
      table.insert(survivors, derbyDamageScoring.buildTimeoutSurvivorRow(playerDerbyVehicleId, true))
    end
    for _, vehId in ipairs(spawnedAiIds) do
      if not eliminatedIds[vehId] then
        table.insert(survivors, derbyDamageScoring.buildTimeoutSurvivorRow(vehId, false))
      end
    end
    derbyDamageScoring.scoreTimeoutSurvivors(survivors)
    table.sort(survivors, function(a, b)
      if a.derbyScore ~= b.derbyScore then return a.derbyScore > b.derbyScore end
      if a.damageDealt ~= b.damageDealt then return a.damageDealt > b.damageDealt end
      if a.damagePct ~= b.damagePct then return a.damagePct < b.damagePct end
      return tostring(a.id) < tostring(b.id)
    end)
    for i, row in ipairs(survivors) do
      if row.isPlayer then
        playerPlacement = i
      else
        eliminatedIds[row.id] = {
          placement = i,
          timedOutSurvivor = true,
          damagePct = row.damagePct,
          derbyScore = row.derbyScore,
          healthScore = row.healthScore,
          damageDealt = row.damageDealt,
          damageDealtScore = row.damageDealtScore,
        }
      end
    end
    local playerWasEliminated = playerEliminated == true
    M.endEvent(playerWasEliminated, playerPlacement or totalParticipants, "time_limit")
    return
  end

  -- Check AI elimination
  local anyEliminated = false
  for _, vehId in ipairs(spawnedAiIds) do
    if not eliminatedIds[vehId] then
      local pos = getVehiclePos(vehId)
      local isEliminated = false
      local damagePct = getVehicleDamageNormalized(vehId, false)
      
      if damagePct >= 100 then
        isEliminated = true
        _log("I", "AI " .. tostring(vehId) .. " eliminated due to 100% damage.")
      elseif pos then
        if isInsideAnyEliminationZone(pos) then
          isEliminated = true
        else
          local vehObj = be:getObjectByID(vehId)
          if vehObj then
            local speed = vehObj:getVelocity():length()
            if speed < STATIONARY_SPEED_THRESHOLD then
              stationaryTimers[vehId] = (stationaryTimers[vehId] or 0) + dtSim
              if stationaryTimers[vehId] >= STATIONARY_ELIMINATION_TIME then
                isEliminated = true
                _log("I", "AI " .. tostring(vehId) .. " eliminated due to being stationary.")
              end
            else
              stationaryTimers[vehId] = 0
            end
          end
        end
      end

      if isEliminated then
        local placement = nextPlacement
        nextPlacement = nextPlacement - 1
        if not firstAiEliminationElapsed then
          firstAiEliminationElapsed = getElapsedEventTime()
        end
        eliminatedIds[vehId] = { placement = placement }
        anyEliminated = true
        local info = spawnedAiInfo[vehId] or {}
        local elimLabel = "AI #" .. tostring(info.index or "?") .. " (" .. tostring(info.model or "?") .. ")"
        _log("I", elimLabel .. " eliminated! Placed " .. ordinal(placement))
        -- Send toast notification to UI
        derbyUi.showEliminationToast({
          label = elimLabel,
          placement = placement,
          placementStr = ordinal(placement),
        })
        setVehicleStopped(vehId, true)
      end
    end
  end

  -- Check player elimination
  local canElimPlayer = not activeEventCfg or activeEventCfg.playerCanBeEliminated ~= false
  if canElimPlayer and not playerEliminated then
    local currentPlayerVehId = be:getPlayerVehicleID(0)
    local isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false
    local exitedEventVehicle = (not currentPlayerVehId) or isWalking or (playerDerbyVehicleId and currentPlayerVehId ~= playerDerbyVehicleId)
    if exitedEventVehicle then
      playerEliminated = true
      local placement = nextPlacement
      nextPlacement = nextPlacement - 1
      playerPlacement = placement
      derbyUi.clearDerbyCountdownWarnings()
      _log("I", "Player eliminated from demo derby for exiting vehicle mid-event. startVeh=" .. tostring(playerDerbyVehicleId) .. " currentVeh=" .. tostring(currentPlayerVehId) .. " walking=" .. tostring(isWalking))
      setVehicleStopped(playerDerbyVehicleId, true)
      M.endEvent(true, placement, "exited_vehicle")
      return
    end

    local playerVehId = currentPlayerVehId

    if updateNoContactTimer(dtSim) then
      playerEliminated = true
      local placement = nextPlacement
      nextPlacement = nextPlacement - 1
      playerPlacement = placement
      derbyUi.clearDerbyCountdownWarnings()
      if ui_message then
        ui_message("No contact! You have been eliminated.", 3, "demoNoContact", "warning")
      end
      _log("I", "Player eliminated from demo derby due to no contact timeout.")
      setVehicleStopped(playerVehId, true)
      M.endEvent(true, placement, "no_contact")
      return
    end

    local ppos = getVehiclePos(playerVehId)
    local isEliminated = false
    local elimReason = "out_of_bounds"
    local damagePct = getVehicleDamageNormalized(playerVehId, true)

    if damagePct >= 100 then
      isEliminated = true
      elimReason = "destroyed"
      derbyUi.clearStationaryWarning()
      _log("I", "Player eliminated due to 100% damage.")
    elseif ppos then
      if isInsideAnyEliminationZone(ppos) then
        isEliminated = true
      else
        local vehObj = be:getObjectByID(playerVehId)
        if vehObj then
          local speed = vehObj:getVelocity():length()
          if speed < STATIONARY_SPEED_THRESHOLD then
            stationaryTimers[playerVehId] = (stationaryTimers[playerVehId] or 0) + dtSim
            if stationaryTimers[playerVehId] >= STATIONARY_ELIMINATION_TIME then
              isEliminated = true
              elimReason = "stationary"
              derbyUi.clearStationaryWarning()
              _log("I", "Player eliminated due to being stationary.")
            else
              local timeLeft = STATIONARY_ELIMINATION_TIME - stationaryTimers[playerVehId]
              if timeLeft <= 10 and timeLeft > 0 then
                derbyUi.showStationaryWarning(timeLeft)
              end
            end
          else
            derbyUi.clearStationaryWarning()
            stationaryTimers[playerVehId] = 0
          end
        end
      end
    end

    if isEliminated then
      playerEliminated = true
      local placement = nextPlacement
      nextPlacement = nextPlacement - 1
      playerPlacement = placement
      _log("I", "Player eliminated from demo derby! Placed " .. ordinal(placement))
      setVehicleStopped(playerVehId, true)
      M.endEvent(true, placement, elimReason)
      return
    end
  end

  -- Check if all AI eliminated → player wins (1st place)
  local allGone = true
  for _, vehId in ipairs(spawnedAiIds) do
    if not eliminatedIds[vehId] then
      allGone = false
      break
    end
  end
  if allGone and #spawnedAiIds > 0 then
    playerPlacement = 1
    M.endEvent(false, 1)
    return
  end

  -- AI activation (delayed start)
  if not aiActivated then
    aiActivationTimer = aiActivationTimer - dtSim
    if aiActivationTimer <= 0 then
      activateAllAi()
    end
  end

  -- AI retargeting and Combat State Machine (Unstick logic)
  if aiActivated then
    -- AI unstick logic & out-of-bounds recovery
    for _, vehId in ipairs(spawnedAiIds) do
      if not eliminatedIds[vehId] then
        local vehObj = be:getObjectByID(vehId)
        local info = spawnedAiInfo[vehId]
        if vehObj and info then
          -- If the target disappeared or was eliminated, reacquire immediately.
          if not isValidTargetForAi(vehId, info.targetId) then
            info.targetId = pickTargetForAi(vehId, false)
            if info.targetId then
              setAiChaseTarget(vehId, info.targetId)
              info.retargetTimer = 0
              info.retargetInterval = getAiRetargetInterval(vehId)
            end
          end

          local pos = vehObj:getPosition()
          local speed = vehObj:getVelocity():length()
          local personality = getAiPersonality(vehId)
          local inPlayZone = isInsidePlayZone(pos)
          local distToEdge = getDistanceToPlayZoneEdge(pos)

          if speed < STATIONARY_SPEED_THRESHOLD then
            info.stationaryTimer = (info.stationaryTimer or 0) + dtSim
            if info.stationaryTimer >= AI_STATIONARY_RECOVERY_TIME then
              local previousTargetId = info.targetId
              local forcedTarget = pickNearestTargetForAi(vehId, previousTargetId)
                or pickTargetForAi(vehId, false, previousTargetId)
                or getSafestTargetId(vehId)
              info.targetId = forcedTarget
              if forcedTarget then
                vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
                vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(forcedTarget) .. ")")
                vehObj:queueLuaCommand("if ai.beginDerbyRecovery then ai.beginDerbyRecovery('stationary') end")
                info.retargetTimer = 0
                info.retargetInterval = getAiRetargetInterval(vehId)
                info.stuckTimer = 0
                info.impactTimer = 0
                info.lastPos = vec3(pos.x, pos.y, pos.z)
              end
              info.stationaryTimer = 0
            end
          else
            info.stationaryTimer = 0
          end

          if info.targetId then

          info.retargetTimer = (info.retargetTimer or 0) + dtSim
          if info.retargetTimer >= (info.retargetInterval or getAiRetargetInterval(vehId)) and info.combatState ~= "recovery" then
            info.retargetTimer = 0
            info.retargetInterval = getAiRetargetInterval(vehId)
            local previousTargetId = info.targetId
            info.targetId = pickNearestTargetForAi(vehId, previousTargetId)
              or pickTargetForAi(vehId, false, previousTargetId)
              or pickTargetForAi(vehId, false)
            setAiChaseTarget(vehId, info.targetId)
          end
          
          local dangerMargin = tonumber(personality and personality.dangerMargin) or 10.0
          local safeMargin = tonumber(personality and personality.safeMargin) or 14.0
          
          local inDangerZone = (not inPlayZone) or (distToEdge < dangerMargin)
          local isSafe = inPlayZone and (distToEdge >= safeMargin)
          
          -- Ensure they avoid the elimination boundaries proactively
          if inDangerZone and info.combatState ~= "recovery" then
            info.combatState = "recovery"
            local safeId = getSafestTargetId(vehId)
            if safeId then
              info.targetId = safeId
              if info.activeMode ~= "demoderby" then
                vehObj:queueLuaCommand("ai.setMode('demoderby')")
                info.activeMode = "demoderby"
              end
              vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(safeId) .. ")")
              _log("I", "AI " .. tostring(vehId) .. " entered prohibited boundary zone, recovering by chasing target " .. tostring(safeId))
            end
          elseif isSafe and info.combatState == "recovery" then
            info.combatState = info.driveMode
            info.stuckTimer = 0
            info.targetId = pickNearestTargetForAi(vehId) or pickTargetForAi(vehId, false)
            setAiChaseTarget(vehId, info.targetId)
            info.retargetTimer = 0
            info.retargetInterval = getAiRetargetInterval(vehId)
          end
          
          local isAttacking = (info.combatState == "demoderby" or info.combatState == "demoderby_reverse")
          
          if isAttacking then
            local targetObj = be:getObjectByID(info.targetId)
            local distToTarget = math.huge
            if targetObj then distToTarget = (pos - targetObj:getPosition()):length() end
            
            -- ── Collision-driven retarget cycle ──
            -- When we detect an impact (very close to target + very slow), start a short
            -- timer. After the timer expires (0.8s), pick a new target. This creates the
            -- "crash → reverse → new target → charge" loop from Green Derby.
            if speed < 1.5 and distToTarget < 8.0 then
              info.impactTimer = (info.impactTimer or 0) + dtSim
              if info.impactTimer >= 0.8 then
                -- Impact confirmed. Pick a new target now.
                info.impactTimer = 0
                local newTargetId = pickNearestTargetForAi(vehId, info.targetId)
                  or pickTargetForAi(vehId, false, info.targetId)
                  or pickTargetForAi(vehId, false)
                info.stuckTimer = 0
                info.retargetTimer = 0
                info.retargetInterval = getAiRetargetInterval(vehId)
                info.lastPos = vec3(pos.x, pos.y, pos.z)
                -- Just update the target — the vehicle-side crash.manoeuvre handles
                -- the reversing physics. We only need to redirect who they charge next.
                if newTargetId then
                  info.targetId = newTargetId
                  vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(newTargetId) .. ")")
                end
              end
            else
              info.impactTimer = 0
            end
            
            -- ── Long-term deadlock fallback ──
            info.stuckTimer = info.stuckTimer + dtSim
            if not info.lastPos then info.lastPos = vec3(pos.x, pos.y, pos.z) end
            
            if info.stuckTimer >= 4.0 then
              local distTraveled = (pos - info.lastPos):length()
              if distTraveled < 3.0 then
                -- Absolutely stuck. Force a new close target and a shove back into motion.
                local newTargetId = pickNearestTargetForAi(vehId, info.targetId)
                  or pickTargetForAi(vehId, false, info.targetId)
                  or pickTargetForAi(vehId, false)
                if newTargetId then
                  info.targetId = newTargetId
                  vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")
                  vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(newTargetId) .. ")")
                  vehObj:queueLuaCommand("if ai.beginDerbyRecovery then ai.beginDerbyRecovery('deadlock') end")
                  info.retargetTimer = 0
                  info.retargetInterval = getAiRetargetInterval(vehId)
                end
              elseif info.targetId then
                vehObj:queueLuaCommand("ai.setTargetObjectID(" .. tostring(info.targetId) .. ")")
              end
              info.stuckTimer = 0
              info.lastPos = vec3(pos.x, pos.y, pos.z)
            end
          end
          end
        end
      end
    end
  end

  -- Throttled HUD update
  hudPushAccum = hudPushAccum + dtSim
  if anyEliminated or hudPushAccum >= HUD_PUSH_INTERVAL then
    hudPushAccum = 0
    derbyUi.pushDemoHudState()
  end
end

-- ── extension lifecycle ────────────────────────────────────────────────────
function M.onExtensionLoaded()
  derbyConfigTypePoolCache = nil
  derbyLevelId = nil
  derbyLevelReady = false
  refreshDerbyForCurrentLevel()
end

function M.onWorldReadyState(state)
  if state ~= 2 then return end
  derbyLevelId = nil
  derbyLevelReady = false
  derbyArenaBarriersVisible = nil
  if eventPhase == "idle" or eventPhase == "configure" then
    configData = nil
    sitesData = nil
  end
  refreshDerbyForCurrentLevel()
end

function M.refreshDerbyVehiclePools()
  derbyConfigTypePoolCache = nil
  return true
end

function M.onExtensionUnloaded()
  if activeEntryModeCfg and activeEntryModeCfg.loaner == true then
    restoreOriginalPlayerVehicle()
  else
    restorePlayerToStagingTransform()
  end
  restoreTrafficAfterEvent()
  clearSpatialData()
  activeEvent = nil
  activeEventCfg = nil
  clearAllAi()

  drawZonesActive = false
  derbyUi.shutdownAll()
  eventActive = false
  eventPhase = "idle"
  hideDerbyArenaBarriers()
end

return M
