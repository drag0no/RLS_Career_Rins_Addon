-- Background race simulation engine for Racing Team
-- Manages 3-phase simulation lifecycle, stochastic 5-car math model, and settlement bridge.
local M = {}

local PHASE_DRIVING_TO_RACE = "driving_to_race"
local PHASE_IN_RACE = "in_race"
local PHASE_DRIVING_FROM_RACE = "driving_from_race"

local DURATION_DRIVING_TO_RACE = 150 -- 2.5 minutes (sim time)
local DURATION_DRIVING_FROM_RACE = 150 -- 2.5 minutes (sim time)
local LAP_TIME_SHORT = 80 -- 80s per lap
local LAP_TIME_LONG = 110 -- 110s per lap

local LAP_DIST_METERS_SHORT = 0.5 * 1609.344 -- ~804.67m
local LAP_DIST_METERS_LONG = 1.4 * 1609.344 -- ~2253.08m

local PACE_SPREAD = 0.075 -- 7.5%
local TRAFFIC_DELAY_PER_CAR = 0.7 -- 0.7s per car ahead on lap 1
local UPDATE_INTERVAL = 1.0 -- 1 Hz throttled tick

local accumulator = 0
local activeSimByBusiness = {}

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

local function getRacingTeam()
  return rawget(_G, "career_modules_business_racingTeam")
end

local function getRacingTeamFleet()
  return rawget(_G, "career_modules_business_racingTeamFleet")
end

local function getInventory()
  return rawget(_G, "career_modules_business_businessInventory")
end

local function getPhoneLayout()
  if not rawget(_G, "ui_phone_layout") and extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  return rawget(_G, "ui_phone_layout")
end

local function isShortTrackRoute(offer)
  if type(offer) ~= "table" then
    return false
  end
  local rType = offer.raceRouteType or offer.requiredRaceRouteType or offer.routeType
  if type(rType) == "string" then
    local lower = string.lower(rType)
    if lower == "short" or lower == "alt" then
      return true
    end
  end
  if offer.useAltRoute == true or offer.isAltRoute == true then
    return true
  end
  local label = string.lower(tostring(offer.raceLabel or offer.raceName or ""))
  if string.find(label, "short") or string.find(label, "alt") then
    return true
  end
  return false
end

local function formatCountdown(sec)
  local s = math.max(0, math.floor(tonumber(sec) or 0))
  local m = math.floor(s / 60)
  local r = s % 60
  return string.format("%d:%02d", m, r)
end

local function randomGauss(mean, stdDev)
  local u1 = math.max(1e-6, math.random())
  local u2 = math.random()
  local z0 = math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)
  return mean + z0 * stdDev
end

local function getAiCompetitorNames()
  return {
    "Marcus Vance",
    "Elena Rostova",
    "Daisuke Sato",
    "Lucas Bennett",
    "Chloe Dupont",
    "Torben Lindholm",
    "Mateo Silva",
    "Siddharth Patel"
  }
end

local function runMathematicalRaceSimulation(opts)
  local pw = opts.carPw or 0.15
  local pwMin = opts.pwMin or 0.10
  local pwMax = opts.pwMax or pwMin
  local driverXp = opts.driverXp or 0
  local isShort = opts.isShortTrack
  local lapCount = math.max(1, opts.lapCount or 3)
  local currentLeague = opts.currentLeague or "league2"

  -- 1. Car Power Score
  local sCar = 0.5
  if pwMax > pwMin then
    sCar = math.max(0.05, math.min(1.0, (pw - pwMin) / (pwMax - pwMin)))
  elseif pwMin > 0 then
    sCar = math.max(0.05, math.min(1.0, (pw - pwMin) / 250))
  end

  -- 2. Driver Skill Score
  local xpRatio = math.min(1.0, math.sqrt(math.max(0, driverXp) / 8000))
  local sDriver = 0.20 + 0.80 * xpRatio

  -- 3. Track Weighting
  local wDriver = isShort and 0.65 or 0.40
  local wCar = isShort and 0.35 or 0.60
  local rProxy = wDriver * sDriver + wCar * sCar

  -- 4. Competitor field (4 AI opponents)
  local leagueRanges = {
    league1 = { min = 0.15, max = 0.45 },
    league2 = { min = 0.25, max = 0.60 },
    league3 = { min = 0.45, max = 0.80 },
    league4 = { min = 0.70, max = 0.98 },
  }
  local lRange = leagueRanges[currentLeague] or leagueRanges.league2
  local rivalScore = lRange.max - math.random() * 0.08 * (lRange.max - lRange.min)

  local poolNames = getAiCompetitorNames()
  -- Shuffle names
  for i = #poolNames, 2, -1 do
    local j = math.random(i)
    poolNames[i], poolNames[j] = poolNames[j], poolNames[i]
  end

  local cars = {}
  -- Player proxy car
  table.insert(cars, {
    isPlayer = true,
    driverName = opts.driverName or "Team Driver",
    vehicleName = opts.vehicleName or "Team Car",
    rating = rProxy,
    sigma = 1.6 - 1.35 * xpRatio,
    pMistake = 0.18 - 0.16 * xpRatio,
    lapTimes = {},
    totalTime = 0,
    bestLap = 999999,
    hadMistake = false,
  })

  -- Opponent 1: strong rival
  table.insert(cars, {
    isPlayer = false,
    driverName = poolNames[1] or "Rival",
    vehicleName = "Rival Car",
    rating = rivalScore,
    sigma = 1.6 - 1.35 * rivalScore,
    pMistake = 0.18 - 0.16 * rivalScore,
    lapTimes = {},
    totalTime = 0,
    bestLap = 999999,
    hadMistake = false,
  })

  -- Opponents 2, 3, 4
  for k = 2, 4 do
    local oppScore = lRange.min + math.random() * (lRange.max - lRange.min)
    table.insert(cars, {
      isPlayer = false,
      driverName = poolNames[k] or ("Competitor #" .. tostring(k)),
      vehicleName = "Competitor Car",
      rating = oppScore,
      sigma = 1.6 - 1.35 * oppScore,
      pMistake = 0.18 - 0.16 * oppScore,
      lapTimes = {},
      totalTime = 0,
      bestLap = 999999,
      hadMistake = false,
    })
  end

  -- Grid Draw: shuffle starting slots 1 to 5
  local gridSlots = { 1, 2, 3, 4, 5 }
  for i = #gridSlots, 2, -1 do
    local j = math.random(i)
    gridSlots[i], gridSlots[j] = gridSlots[j], gridSlots[i]
  end

  local tBase = isShort and LAP_TIME_SHORT or LAP_TIME_LONG

  -- Simulate laps and grid traffic
  for idx, car in ipairs(cars) do
    local gridPos = gridSlots[idx] or idx
    local carsAhead = gridPos - 1
    local trafficPenalty = carsAhead * TRAFFIC_DELAY_PER_CAR
    local baseLap = tBase * (1.0 + (1.0 - car.rating) * PACE_SPREAD)

    car.gridPos = gridPos
    car.totalTime = trafficPenalty

    for lap = 1, lapCount do
      local noise = randomGauss(0, car.sigma)
      local lapTime = baseLap + noise
      if math.random() < car.pMistake then
        local mistakePenalty = 2.0 + math.random() * 2.5
        lapTime = lapTime + mistakePenalty
        car.hadMistake = true
      end
      lapTime = math.max(tBase * 0.85, lapTime)
      table.insert(car.lapTimes, lapTime)
      car.totalTime = car.totalTime + lapTime
      if lapTime < car.bestLap then
        car.bestLap = lapTime
      end
    end
  end

  -- Sort by total time ascending
  table.sort(cars, function(a, b)
    return a.totalTime < b.totalTime
  end)

  local aiResults = {}
  local playerPlace = 5
  local playerHadMistake = false

  for p, car in ipairs(cars) do
    car.place = p
    if car.isPlayer then
      playerPlace = p
      playerHadMistake = car.hadMistake
    end
    table.insert(aiResults, {
      place = p,
      isPlayer = car.isPlayer,
      driverName = car.driverName,
      vehicleName = car.vehicleName,
      totalTime = car.totalTime,
      bestLap = car.bestLap,
      gridPos = car.gridPos,
    })
  end

  return {
    aiResults = aiResults,
    playerPlace = playerPlace,
    playerHadMistake = playerHadMistake,
  }
end

function M.getActiveSim(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return activeSimByBusiness[id]
end

function M.getDriverSimState(businessId, driverId)
  local id = tostring(normalizeBusinessId(businessId))
  local sim = activeSimByBusiness[id]
  if not sim or tonumber(sim.driverId) ~= tonumber(driverId) then
    return nil
  end

  local remaining = math.max(0, sim.stateDuration - sim.stateElapsed)
  local progress = sim.stateDuration > 0 and math.min(1.0, sim.stateElapsed / sim.stateDuration) or 0

  local badge = ""
  if sim.phase == PHASE_DRIVING_TO_RACE then
    badge = string.format("Driving to race (%s remaining)", formatCountdown(remaining))
  elseif sim.phase == PHASE_IN_RACE then
    local lapBaseTime = sim.isShortTrack and LAP_TIME_SHORT or LAP_TIME_LONG
    local currentLap = math.min(sim.lapCount, math.floor(sim.stateElapsed / lapBaseTime) + 1)
    badge = string.format("In Race (Lap %d/%d - %s remaining)", currentLap, sim.lapCount, formatCountdown(remaining))
  elseif sim.phase == PHASE_DRIVING_FROM_RACE then
    badge = string.format("Returning to HQ (%s remaining)", formatCountdown(remaining))
  end

  return {
    phase = sim.phase,
    stateElapsed = sim.stateElapsed,
    stateDuration = sim.stateDuration,
    progress = progress,
    remainingSec = remaining,
    badge = badge,
    canSpectate = (sim.phase == PHASE_DRIVING_TO_RACE),
    isShortTrack = sim.isShortTrack,
    lapCount = sim.lapCount,
  }
end

function M.startBackgroundRace(businessId, driverId)
  businessId = normalizeBusinessId(businessId)
  driverId = tonumber(driverId)
  if not businessId or not driverId then
    return { ok = false, err = "missing_business_or_driver" }
  end

  local rt = getRacingTeam()
  if not rt then
    return { ok = false, err = "no_racing_team" }
  end

  if not rt.hasManagerLevel1 or not rt.hasManagerLevel1(businessId) then
    return { ok = false, err = "requires_manager_level_1" }
  end

  local id = tostring(businessId)
  if activeSimByBusiness[id] then
    return { ok = false, err = "manager_already_running_race" }
  end

  local tech = rt.getRacingTeamDriverById and rt.getRacingTeamDriverById(businessId, driverId)
  if not tech or tech.fired then
    return { ok = false, err = "invalid_driver" }
  end

  if not tech.pendingRaceOffer then
    return { ok = false, err = "no_pending_race_offer" }
  end

  if rt.isScheduledRaceReadyForDriver and not rt.isScheduledRaceReadyForDriver(businessId, driverId) then
    return { ok = false, err = "race_not_scheduled_yet" }
  end

  local fleetVehicleId = tech.fleetVehicleId
  if not fleetVehicleId then
    return { ok = false, err = "no_valid_fleet_vehicle" }
  end

  local offer = tech.pendingRaceOffer
  if rt.isOfferBlockedByDyno and rt.isOfferBlockedByDyno(businessId, fleetVehicleId, offer) then
    return { ok = false, err = "dyno_required" }
  end
  if rt.fleetVehicleOverpoweredForOffer and rt.fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, offer) then
    return { ok = false, err = "fleet_hp_over_class_max" }
  end
  local isShort = isShortTrackRoute(offer)
  local lapCount = math.max(1, math.floor(tonumber(offer.lapCount) or 3))
  local raceDuration = lapCount * (isShort and LAP_TIME_SHORT or LAP_TIME_LONG)

  -- Gather PW and vehicle info
  local carPw = 0.15
  local rawV = rt.getBusinessVehicleRawByInventoryId and rt.getBusinessVehicleRawByInventoryId(businessId, fleetVehicleId)
  if rawV and rt.getEffectiveTeamJobVehiclePw then
    carPw = tonumber(rt.getEffectiveTeamJobVehiclePw(businessId, rawV)) or carPw
  end

  local pwMin = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local pwMax = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or pwMin
  if pwMax < pwMin then
    pwMin, pwMax = pwMax, pwMin
  end

  local currentLeague = rt.getCurrentLeague and rt.getCurrentLeague(businessId) or "league2"

  -- Run mathematical simulation upfront
  local mathOutcome = runMathematicalRaceSimulation({
    carPw = carPw,
    pwMin = pwMin,
    pwMax = pwMax,
    driverXp = tech.racingSkillXp or 0,
    driverName = tech.name,
    vehicleName = tech.fleetVehicleName,
    isShortTrack = isShort,
    lapCount = lapCount,
    currentLeague = currentLeague,
  })

  -- Put away vehicle before state is set
  local bizComputer = rawget(_G, "career_modules_business_businessComputer")
  if bizComputer then bizComputer.putAwayVehicle(businessId, fleetVehicleId) end

  -- Set simulation state
  activeSimByBusiness[id] = {
    businessId = businessId,
    driverId = driverId,
    fleetVehicleId = fleetVehicleId,
    offer = offer,
    phase = PHASE_DRIVING_TO_RACE,
    stateElapsed = 0,
    stateDuration = DURATION_DRIVING_TO_RACE,
    raceDuration = raceDuration,
    isShortTrack = isShort,
    lapCount = lapCount,
    simResults = mathOutcome,
  }

  tech.currentAction = PHASE_DRIVING_TO_RACE
  tech.phase = PHASE_DRIVING_TO_RACE

  if rt.notifyRacingTeamDriversUpdated then
    rt.notifyRacingTeamDriversUpdated(businessId)
  end

  local _, savePath = career_saveSystem and career_saveSystem.getCurrentProfile and career_saveSystem.getCurrentProfile()
  if savePath and rt.saveRacingTeamPersistedState then
    rt.saveRacingTeamPersistedState(businessId, savePath)
  end

  log("I", "racingTeamRaceSim", string.format("Started background race for driver %d in business %s", driverId, tostring(businessId)))
  return { ok = true }
end

function M.cancelBackgroundRace(businessId, driverId, reason)
  businessId = normalizeBusinessId(businessId)
  local id = tostring(businessId)
  local sim = activeSimByBusiness[id]
  if not sim then
    return { ok = false, err = "no_active_sim" }
  end

  if driverId and tonumber(sim.driverId) ~= tonumber(driverId) then
    return { ok = false, err = "driver_mismatch" }
  end

  if sim.phase ~= PHASE_DRIVING_TO_RACE then
    return { ok = false, err = "race_in_progress" }
  end

  activeSimByBusiness[id] = nil

  local rt = getRacingTeam()
  if not rt then
    return { ok = true }
  end

  local tech = rt.getRacingTeamDriverById and rt.getRacingTeamDriverById(businessId, sim.driverId)
  if tech then
    if reason == "manage_myself" then
      tech.currentAction = "race_pending"
      tech.phase = "idle"
      if rt.racingTeamPersistDrivers then
        rt.racingTeamPersistDrivers(businessId)
      end
      if rt.notifyRacingTeamDriversUpdated then
        rt.notifyRacingTeamDriversUpdated(businessId)
      end
      local _, savePath = career_saveSystem and career_saveSystem.getCurrentProfile and career_saveSystem.getCurrentProfile()
      if savePath and rt.saveRacingTeamPersistedState then
        rt.saveRacingTeamPersistedState(businessId, savePath)
      end
    elseif reason == "drop_out" or reason == "dropped" then
      tech.currentAction = "idle"
      tech.phase = "idle"
    end
  end

  return { ok = true }
end

local function settleBackgroundRace(businessId)
  local id = tostring(businessId)
  local sim = activeSimByBusiness[id]
  if not sim then
    return
  end

  activeSimByBusiness[id] = nil

  local rt = getRacingTeam()
  if not rt then
    return
  end

  local offer = sim.offer
  local results = sim.simResults and sim.simResults.aiResults

  -- 1. Settle with standard banking, XP, goals, and driver cut
  local settlementResult = nil
  if rt.settleProxySanctionedRaceFromAiResults and results then
    local override = {offer=offer, driverId=sim.driverId}
    settlementResult = rt.settleProxySanctionedRaceFromAiResults(businessId, results, true, override)
  end

  -- 2. Accumulate odometer mileage
  local lapDist = sim.isShortTrack and LAP_DIST_METERS_SHORT or LAP_DIST_METERS_LONG
  local addedMeters = sim.lapCount * lapDist
  local inv = getInventory()
  local vehRow = nil
  if inv and inv.getVehicleById and sim.fleetVehicleId then
    vehRow = inv.getVehicleById(businessId, sim.fleetVehicleId)
    if vehRow then
      vehRow.mileage = (vehRow.mileage or 0) + addedMeters
    end
  end

  -- 3. Incident damage risk (scaled by driver XP / mistakes)
  if sim.simResults and sim.simResults.playerHadMistake and vehRow and vehRow.partConditions then
    -- Light contact damage
    for _, partCond in pairs(vehRow.partConditions) do
      if type(partCond) == "table" and partCond.integrityValue then
        if math.random() < 0.25 then
          partCond.integrityValue = math.max(0.60, partCond.integrityValue - (0.02 + math.random() * 0.05))
        end
      end
    end
  end

  if vehRow and inv and inv.saveBusinessVehicles then
    local _, savePath = career_saveSystem and career_saveSystem.getCurrentProfile and career_saveSystem.getCurrentProfile()
    if savePath then
      inv.saveBusinessVehicles(businessId, savePath)
    end
  end

  -- 4. Arm driver & vehicle cooldown and clear pending offer
  local tech = rt.getRacingTeamDriverById(businessId, sim.driverId)
  if tech then
    local rtf = getRacingTeamFleet()
    local cdSec = rtf and rtf.getRacingTeamPostRaceCooldownSeconds and rtf.getRacingTeamPostRaceCooldownSeconds(businessId) or 900
    local nowSim = rt.getCareerSimTime() or os.time()
    tech.racingCooldownUntilSimTime = nowSim + cdSec
    tech.postRaceCooldownReadyWallEpoch = os.time() + cdSec
    tech.pendingRaceOffer = nil
    tech.currentAction = "idle"
    tech.phase = "idle"
  end
  if sim.fleetVehicleId and rt.armFleetVehiclePostRaceCooldown then
    rt.armFleetVehiclePostRaceCooldown(businessId, sim.fleetVehicleId)
  end

  if rt.racingTeamPersistDrivers then
    rt.racingTeamPersistDrivers(businessId)
  end

  local _, savePath = career_saveSystem and career_saveSystem.getCurrentProfile and career_saveSystem.getCurrentProfile()
  if savePath and rt.saveRacingTeamPersistedState then
    rt.saveRacingTeamPersistedState(businessId, savePath)
  end

  if rt.notifyRacingTeamDriversUpdated then
    rt.notifyRacingTeamDriversUpdated(businessId)
  end

  -- 5. Dispatch phone notification
  local playerPlace = sim.simResults and sim.simResults.playerPlace or 1
  local driverName = tech and tech.name or "Driver"
  local xpEarned = settlementResult and settlementResult.businessSkillXp or 0
  local grossMoney = settlementResult and settlementResult.money or 0
  local netMoney = grossMoney
  if grossMoney > 0 and rt.driverCutPercentFromRacingXp and tech then
    local pct = math.floor(rt.driverCutPercentFromRacingXp(tech.racingSkillXp or 0) + 0.5)
    netMoney = math.max(0, grossMoney - math.floor(grossMoney * pct / 100 + 0.5))
  end
  local layout = getPhoneLayout()
  if layout and layout.fireNotification then
    local title = (playerPlace <= 3) and string.format("P%d Podium!", playerPlace) or string.format("P%d Finish", playerPlace)
    local moneyStr = netMoney > 0 and string.format("+$%d net", netMoney) or (playerPlace <= 3 and string.format("+$%d", netMoney) or "+$0")
    local xpStr = xpEarned >= 0 and string.format("+%d XP", xpEarned) or "+0 XP"
    local rewardStr = string.format(" (%s, %s)", moneyStr, xpStr)
    local raceLabel = offer and (offer.name or offer.trackName or offer.raceLabel) or "Sanctioned Race"
    layout.fireNotification("racingTeam.raceFinished", {
      title = title,
      message = string.format("%s finished P%d%s", driverName, playerPlace, rewardStr),
      meta = raceLabel,
      kind = playerPlace <= 3 and "info" or "warning",
      ttl = 10,
      source = "Racing Team",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
    }, { appId = "racing-team" })
  end

  log("I", "racingTeamRaceSim", string.format("Background race settled for business %s: P%d", tostring(businessId), playerPlace))
end

function M.checkAutoStart(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end

  local id = tostring(businessId)
  if activeSimByBusiness[id] then
    return
  end

  local rt = getRacingTeam()
  if not rt or not rt.hasManagerLevel2 or not rt.hasManagerLevel2(businessId) then
    return
  end

  if rt.getAutoStartBackgroundRaces and not rt.getAutoStartBackgroundRaces(businessId) then
    return
  end

  local drivers = rt.loadRacingTeamDrivers and rt.loadRacingTeamDrivers(businessId) or {}
  for _, tech in ipairs(drivers) do
    if tech and not tech.fired and tech.pendingRaceOffer then
      if rt.isScheduledRaceReadyForDriver and rt.isScheduledRaceReadyForDriver(businessId, tech.id) then
        local fleetVehicleId = tech.fleetVehicleId
        local offer = tech.pendingRaceOffer
        local blocked = rt.isOfferBlockedByDyno(businessId, fleetVehicleId, offer) or rt.fleetVehicleOverpoweredForOffer(businessId, fleetVehicleId, offer)
        if not blocked then
          M.startBackgroundRace(businessId, tech.id)
          return
        end
      end
    end
  end
end

function M.tickAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end

  accumulator = accumulator + dtSim
  if accumulator < UPDATE_INTERVAL then
    return
  end

  local step = math.min(accumulator, 10.0)
  accumulator = 0

  local bm = career_modules_business_businessManager
  if not bm or not bm.getPurchasedBusinesses then
    return
  end

  local purchased = bm.getPurchasedBusinesses("racingTeam")
  if type(purchased) ~= "table" then
    return
  end

  local rt = getRacingTeam()

  for bid, owned in pairs(purchased) do
    if owned then
      local nBid = normalizeBusinessId(bid)
      local id = tostring(nBid)
      local sim = activeSimByBusiness[id]

      if sim then
        sim.stateElapsed = sim.stateElapsed + step

        if sim.phase == PHASE_DRIVING_TO_RACE then
          if sim.stateElapsed >= sim.stateDuration then
            local excess = sim.stateElapsed - sim.stateDuration
            sim.phase = PHASE_IN_RACE
            sim.stateElapsed = excess
            sim.stateDuration = sim.raceDuration
          end
        elseif sim.phase == PHASE_IN_RACE then
          if sim.stateElapsed >= sim.stateDuration then
            local excess = sim.stateElapsed - sim.stateDuration
            sim.phase = PHASE_DRIVING_FROM_RACE
            sim.stateElapsed = excess
            sim.stateDuration = DURATION_DRIVING_FROM_RACE
          end
        elseif sim.phase == PHASE_DRIVING_FROM_RACE then
          if sim.stateElapsed >= sim.stateDuration then
            settleBackgroundRace(nBid)
          end
        end
        -- Push updated progress/badge to Vue on every 1 Hz tick
        if activeSimByBusiness[id] and rt and rt.notifyRacingTeamDriversUpdated then
          rt.notifyRacingTeamDriversUpdated(nBid)
        end
      else
        M.checkAutoStart(nBid)
      end
    end
  end
end

function M.onSaveCurrentProfile(currentSavePath)
  -- Active simulation state is returned to racingTeam.saveRacingTeamPersistedState
end

function M.getPersistedStateForSave(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return activeSimByBusiness[id]
end

function M.loadPersistedState(businessId, data)
  local id = tostring(normalizeBusinessId(businessId))
  if type(data) == "table" and data.phase then
    activeSimByBusiness[id] = data
  else
    activeSimByBusiness[id] = nil
  end
end

function M.onCareerActivated()
  accumulator = 0
  activeSimByBusiness = {}
end

M.DRIVER_DRIVING_TO_RACE = PHASE_DRIVING_TO_RACE
M.DRIVER_IN_RACE = PHASE_IN_RACE
M.DRIVER_DRIVING_FROM_RACE = PHASE_DRIVING_FROM_RACE

return M
