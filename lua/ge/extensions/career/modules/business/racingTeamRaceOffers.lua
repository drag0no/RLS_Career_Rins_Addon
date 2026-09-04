local M = {}

local rtState = require('ge/extensions/career/modules/business/racingTeamRuntimeState')

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

function M.getBoard(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  if not rtState.raceOfferBoardByBusiness[id] then
    rtState.raceOfferBoardByBusiness[id] = {
      levelId = "",
      nextRefreshAt = 0,
      offers = {},
    }
  end
  return rtState.raceOfferBoardByBusiness[id]
end

function M.getPendingRematch(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  return rtState.pendingRematchOfferByBusiness[id]
end

function M.setPendingRematch(businessId, offer)
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return
  end
  local id = tostring(bid)
  if type(offer) == "table" then
    rtState.pendingRematchOfferByBusiness[id] = offer
  else
    rtState.pendingRematchOfferByBusiness[id] = nil
  end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.rtInternal.getOfferState(bid)
    rtState.rtInternal.saveRacingTeamPersistedState(bid, savePath)
  end
end

function M.removeOfferById(board, offerId)
  if not board or type(board.offers) ~= "table" then
    return false
  end
  local want = tostring(offerId)
  for i, o in ipairs(board.offers) do
    if o and tostring(o.id) == want then
      table.remove(board.offers, i)
      return true
    end
  end
  return false
end

function M.normalizeLineupSnapshot(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, row in ipairs(list) do
    if type(row) == "table" and type(row.model) == "string" and type(row.config) == "string"
        and row.model ~= "" and row.config ~= "" then
      table.insert(out, {
        model = row.model,
        config = row.config,
        matchPw = tonumber(row.matchPw) or tonumber(row.powerHp) or nil,
      })
    end
  end
  return out
end

function M.lineupMaxPw(lineup, fallbackPw)
  local best = nil
  if type(lineup) == "table" then
    for _, row in ipairs(lineup) do
      local pw = tonumber(row and row.matchPw) or tonumber(row and row.powerHp)
      if pw and pw > 0 and (not best or pw > best) then
        best = pw
      end
    end
  end
  if best and best > 0 then
    return best
  end
  local fb = tonumber(fallbackPw)
  if fb and fb > 0 then
    return fb
  end
  return nil
end

function M.ensurePendingRematchOnBoard(businessId)
  local bid = normalizeBusinessId(businessId)
  local pending = M.getPendingRematch(bid)
  if type(pending) ~= "table" then
    return
  end
  local board = M.getBoard(bid)
  if type(board.offers) ~= "table" then
    board.offers = {}
  end
  for _, o in ipairs(board.offers) do
    if o and tostring(o.id) == tostring(pending.id) then
      return
    end
  end
  table.insert(board.offers, 1, pending)
  while #board.offers > rtState.rtInternal.getMaxRaceOffersOnBoard(businessId) do
    table.remove(board.offers, #board.offers)
  end
end

function M.bumpRefresh(businessId)
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return
  end
  local board = M.getBoard(bid)
  if board then
    board.nextRefreshAt = 0
  end
end

function M.rollOneOffer(levelId, now, options)
  local sr = gameplay_events_freContracts_sanctionedRacing
  if not sr or not sr.rollRacingTeamSanctionedOffer then
    return nil
  end
  return sr.rollRacingTeamSanctionedOffer(levelId, nil, now, options)
end

local function getFleetEffectivePws(businessId)
  local out = {}
  if not career_modules_business_businessInventory or not career_modules_business_businessInventory.getBusinessVehicles then
    local best = rtState.rtInternal.getBestTeamJobVehiclePw(businessId)
    if best and best > 0 then
      out[1] = best
    end
    return out
  end
  for _, v in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
    local pw = rtState.rtInternal.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and pw > 0 then
      table.insert(out, pw)
    end
  end
  if #out == 0 then
    local best = rtState.rtInternal.getBestTeamJobVehiclePw(businessId)
    if best and best > 0 then
      out[1] = best
    end
  end
  return out
end

local function offerRouteBucket(offer)
  local rt = string.lower(tostring(offer and offer.raceRouteType or ""))
  local rl = string.lower(tostring(offer and offer.raceLabel or ""))
  if rt == "alt" or string.find(rl, "short", 1, true) then
    return "short"
  end
  return "track"
end

local function offerMatchesAnyFleetPw(offer, fleetPws)
  if type(offer) ~= "table" or type(fleetPws) ~= "table" or #fleetPws == 0 then
    return false
  end
  local lo = tonumber(offer.classPwMin) or tonumber(offer.classHpMin) or 0
  local hi = tonumber(offer.classPwMax) or tonumber(offer.classHpMax) or lo
  if hi < lo then
    lo, hi = hi, lo
  end
  for _, pw in ipairs(fleetPws) do
    if pw >= lo and pw <= hi then
      return true
    end
  end
  return false
end

local function offerQuotaSlotKey(offer, fleetPws)
  local route = offerRouteBucket(offer)
  local spec = offerMatchesAnyFleetPw(offer, fleetPws) and "in" or "out"
  return spec .. "_" .. route
end

local function offerUniqKey(offer)
  return string.format(
    "%s|%s|%s|%s|%s",
    tostring(offer and offer.raceName or ""),
    tostring(offer and offer.raceRouteType or ""),
    tostring(offer and offer.hpBracketId or ""),
    tostring(offer and offer.classPwMin or ""),
    tostring(offer and offer.classPwMax or "")
  )
end

local BRANCH_RANK = { stock = 1, modified = 2, super = 3, open = 4 }

local function branchFromRank(r)
  r = math.floor(tonumber(r) or 1)
  if r >= 4 then
    return "open"
  end
  if r >= 3 then
    return "super"
  end
  if r >= 2 then
    return "modified"
  end
  return "stock"
end

local function nextBranchUp(branch)
  local r = BRANCH_RANK[string.lower(tostring(branch or ""))] or 1
  return branchFromRank(r + 1)
end

local function getFleetRollContext(businessId)
  local fleetPws = getFleetEffectivePws(businessId)
  local fleetCars = {}
  if career_modules_business_businessInventory and career_modules_business_businessInventory.getBusinessVehicles then
    for _, v in ipairs(career_modules_business_businessInventory.getBusinessVehicles(businessId) or {}) do
      local pw = rtState.rtInternal.getEffectiveTeamJobVehiclePw(businessId, v)
      if pw and pw > 0 then
        table.insert(fleetCars, {
          pw = pw,
          branch = rtState.rtInternal.resolveFleetVehicleSanctionedBranch(businessId, v),
        })
      end
    end
  end
  if #fleetCars == 0 then
    for _, pw in ipairs(fleetPws) do
      table.insert(fleetCars, { pw = pw, branch = nil })
    end
  end
  local bestPw = nil
  for _, pw in ipairs(fleetPws) do
    if pw and (not bestPw or pw > bestPw) then
      bestPw = pw
    end
  end
  local fleetBranch = rtState.rtInternal.getSanctionedBranchFilterForBusiness(businessId) or "stock"
  local samplePw = bestPw
  if #fleetCars > 0 then
    samplePw = fleetCars[math.random(1, #fleetCars)].pw
  elseif #fleetPws > 0 then
    samplePw = fleetPws[math.random(1, #fleetPws)]
  end
  return {
    fleetPws = fleetPws,
    fleetCars = fleetCars,
    bestPw = bestPw,
    samplePw = samplePw,
    fleetBranch = fleetBranch,
    aspirationalBranch = nextBranchUp(fleetBranch),
  }
end

local function fleetCarForSlot(ctx, slotIndex)
  local cars = ctx.fleetCars
  if type(cars) ~= "table" or #cars == 0 then
    return nil
  end
  local idx = ((tonumber(slotIndex) or 1) - 1) % #cars + 1
  return cars[idx]
end

local function buildQuotaSlotOrder(wantCount)
  local order = { "in_track", "in_short" }
  if wantCount >= 3 then
    table.insert(order, "out_track")
  end
  return order
end

local function rollOptionsForQuotaSlot(slotKey, ctx, slotIndex)
  local isOut = string.sub(slotKey, 1, 3) == "out"
  local routeBucket = (slotKey == "in_short" or slotKey == "out_short") and "short" or "track"
  local car = fleetCarForSlot(ctx, slotIndex)
  local pwRef = (car and car.pw) or ctx.samplePw or ctx.bestPw
  if isOut then
    return {
      routeBucket = routeBucket,
      branchFilter = ctx.aspirationalBranch,
      bracketPick = "above_fleet_pw",
      pwReference = ctx.bestPw or pwRef,
    }
  end
  return {
    routeBucket = routeBucket,
    bracketPick = "fleet_pw",
    pwReference = pwRef,
  }
end

local function fillRaceOfferBoardWithQuota(businessId, board, levelId, now, targetCount)
  local wantCount = math.max(1, tonumber(targetCount) or 1)
  local ctx = getFleetRollContext(businessId)
  local fleetPws = ctx.fleetPws
  local slotOrder = buildQuotaSlotOrder(wantCount)
  local targetSlots = {}
  for _, sk in ipairs(slotOrder) do
    targetSlots[sk] = true
  end
  local haveSlots = {}
  local chosen = {}
  local chosenByKey = {}
  local overflowIn = {}

  local function tryTake(o, onlySlot)
    if type(o) ~= "table" then
      return false
    end
    local k = offerUniqKey(o)
    if chosenByKey[k] then
      return false
    end
    local sk = offerQuotaSlotKey(o, fleetPws)
    if onlySlot and sk ~= onlySlot then
      return false
    end
    if targetSlots[sk] and not haveSlots[sk] then
      haveSlots[sk] = true
      chosenByKey[k] = true
      table.insert(chosen, o)
      return true
    end
    if not onlySlot and string.sub(sk, 1, 3) == "in" then
      overflowIn[k] = o
    end
    return false
  end

  for _, o in ipairs(board.offers or {}) do
    if #chosen >= wantCount then
      break
    end
    tryTake(o)
  end

  local maxAttemptsPerSlot = 40
  for slotIndex, slotKey in ipairs(slotOrder) do
    if haveSlots[slotKey] or #chosen >= wantCount then
      break
    end
    local attempts = 0
    while not haveSlots[slotKey] and attempts < maxAttemptsPerSlot do
      attempts = attempts + 1
      local o = M.rollOneOffer(levelId, now, rollOptionsForQuotaSlot(slotKey, ctx, slotIndex))
      if o then
        tryTake(o, slotKey)
      end
    end
  end

  local extraAttempts = 0
  while #chosen < wantCount and extraAttempts < 80 do
    extraAttempts = extraAttempts + 1
    for _, o in pairs(overflowIn) do
      if #chosen >= wantCount then
        break
      end
      tryTake(o)
    end
    if #chosen >= wantCount then
      break
    end
    local extraCar = fleetCarForSlot(ctx, #chosen + 1)
    local o = M.rollOneOffer(levelId, now, {
      routeBucket = (#chosen % 2 == 0) and "short" or "track",
      bracketPick = "fleet_pw",
      pwReference = (extraCar and extraCar.pw) or ctx.samplePw or ctx.bestPw,
    })
    if not o then
      break
    end
    local k = offerUniqKey(o)
    if not chosenByKey[k] then
      if not tryTake(o) then
        overflowIn[k] = o
      end
    end
  end

  board.offers = chosen
end

function M.ensureBoard(businessId)
  rtState.rtInternal.getOfferState(businessId)
  local board = M.getBoard(businessId)
  local levelId = rtState.rtInternal.getRacingTeamLevelId()
  local now = rtState.rtInternal.getCareerSimTime()
  local sr = gameplay_events_freContracts_sanctionedRacing
  if not sr or not sr.loadCfgForLevel or not sr.rollRacingTeamSanctionedOffer then
    board.offers = board.offers or {}
    return board
  end
  if levelId == "" then
    board.offers = {}
    board.levelId = ""
    board.nextRefreshAt = 0
    return board
  end
  local bid = tostring(normalizeBusinessId(businessId))
  local gDone = rtState.goalCompletionByBusiness[bid] or {}
  if not gDone[rtState.K.GOAL_UNLOCK_SANCTIONED_RACE_OFFERS] then
    board.offers = {}
    board.levelId = levelId
    board.nextRefreshAt = 0
    return board
  end
  local cfg = sr.loadCfgForLevel(levelId)
  local refreshMin = math.max(0.25, tonumber(cfg.defaultOfferRefreshMinutes) or 20)
  local refreshSec = math.max(15, refreshMin * 60)
  local needRegen = board.levelId ~= levelId
    or #board.offers == 0
    or now >= (tonumber(board.nextRefreshAt) or 0)
  if needRegen and sr.rollRacingTeamSanctionedOffer then
    board.offers = {}
    fillRaceOfferBoardWithQuota(businessId, board, levelId, now, rtState.rtInternal.getMaxRaceOffersOnBoard(businessId))
    board.levelId = levelId
    board.nextRefreshAt = now + refreshSec
  end
  M.ensurePendingRematchOnBoard(businessId)
  return board
end

function M.topUp(businessId)
  rtState.rtInternal.getOfferState(businessId)
  local bid = tostring(normalizeBusinessId(businessId))
  if not (rtState.goalCompletionByBusiness[bid] or {})[rtState.K.GOAL_UNLOCK_SANCTIONED_RACE_OFFERS] then
    return
  end
  local board = M.getBoard(businessId)
  local levelId = board.levelId
  if levelId == "" then
    return
  end
  local now = rtState.rtInternal.getCareerSimTime()
  local sr = gameplay_events_freContracts_sanctionedRacing
  if sr and sr.rollRacingTeamSanctionedOffer then
    local maxOffers = rtState.rtInternal.getMaxRaceOffersOnBoard(businessId)
    local nextRefreshAt = tonumber(board.nextRefreshAt) or 0
    if #board.offers >= maxOffers and now < nextRefreshAt then
      M.ensurePendingRematchOnBoard(businessId)
      return
    end
    fillRaceOfferBoardWithQuota(businessId, board, levelId, now, maxOffers)
  end
  M.ensurePendingRematchOnBoard(businessId)
end

return M
