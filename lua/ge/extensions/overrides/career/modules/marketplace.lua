-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui

local listedVehicles = {}

local TIME_BETWEEN_OFFERS_BASE = 95
local OFFER_TTL = 500
local OFFER_TTL_VARIANCE = 0.5
local VALUE_LOSS_LIMIT = 0.95
local MAXIMUM_EXPIRED_OFFERS = 3

local MIN_RATIO_DENOMINATOR = 1

local PHONE_NOTIF_SOUND = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
local DETAILED_OFFER_BANNER_LIMIT = 3
local DETAILED_OFFER_TTL = 8
local DIGEST_OFFER_TTL = 15
local DIGEST_REPLACE_KEY = "marketplace.offerDigest"

local detailedOfferBannersShown = 0
local digestBannerActive = false

local function getPhoneLayout()
  if not ui_phone_layout and extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  return ui_phone_layout
end

local function fireMarketplacePhoneNotification(channelKey, title, message, meta, kind, opts)
  local layout = getPhoneLayout()
  if not (layout and layout.fireNotification) then
    return false
  end
  opts = opts or {}
  local sound
  if opts.sound == false then
    sound = false
  else
    sound = opts.sound or PHONE_NOTIF_SOUND
  end
  local payload = {
    title = title,
    message = message,
    meta = meta,
    kind = kind or "invite",
    ttl = opts.ttl or DETAILED_OFFER_TTL,
    source = "Marketplace",
    sound = sound,
  }
  if opts.forceTtl then
    payload.forceTtl = true
  end
  if type(opts.replaceKey) == "string" and opts.replaceKey ~= "" then
    payload.replaceKey = opts.replaceKey
  end
  return layout.fireNotification(channelKey, payload)
end

local function countPendingOffers()
  local count = 0
  for _, listing in ipairs(listedVehicles) do
    for _, offer in ipairs(listing.offers or {}) do
      if not offer.expiredViewCounter then
        count = count + 1
      end
    end
  end
  return count
end

local function isStandoutOffer(listing, offerValue)
  local asking = tonumber(listing.value) or 0
  if asking > 0 and offerValue >= asking then
    return true
  end
  local market = tonumber(listing.marketValue) or tonumber(listing.marketValueAtListing) or asking
  if market > 0 and offerValue >= market * 0.95 then
    return true
  end
  local previousBest = tonumber(listing.bestOfferValue)
  if not previousBest or offerValue > previousBest then
    return true
  end
  return false
end

local function resetOfferBannerDigest()
  detailedOfferBannersShown = 0
  digestBannerActive = false
end

local function marketRatioDenominator(marketValue)
  return math.max(tonumber(marketValue) or 0, MIN_RATIO_DENOMINATOR)
end

local function offerTimeMultiplierForRatio(marketRatio)
  if marketRatio >= 0.98 and marketRatio <= 1.1 then
    return 1
  end
  if marketRatio < 0.98 then
    local t = math.max(0, math.min(1, inverseLerp(0.98, 0.85, marketRatio)))
    return lerp(1, 0.4, t)
  end
  if marketRatio > 1.1 then
    local t = math.max(0, math.min(1, inverseLerp(1.1, 1.5, marketRatio)))
    return lerp(1, 4.0, t)
  end
  return 1
end

local function roundListingPrice(value)
  local n = tonumber(value)
  if not n or n <= 0 then
    return nil
  end
  return math.max(50, math.floor((n + 25) / 50) * 50)
end

local offerMenuOpen = false
local getListings
local selectQuoteForPersonality

local function isListingValueManual(listing)
  return listing and listing.isManualValue
end

local function refreshLiveListingValues(listing)
  if not listing or not listing.id then
    return
  end
  if listing.rtBiz then
    return
  end

  local currentMarketValue = career_modules_valueCalculator.getInventoryVehicleSellValue(listing.id)
  if not currentMarketValue then
    return
  end

  if listing.isManualValue == nil then
    listing.isManualValue = listing.value ~= (listing.marketValueAtListing or listing.marketValue)
  end

  listing.marketValue = currentMarketValue
  listing.marketValueCurrent = currentMarketValue
  if not isListingValueManual(listing) then
    listing.value = currentMarketValue
  end
end

local function findVehicleListing(inventoryId)
  for _, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId or tostring(listing.id) == tostring(inventoryId) then
      return listing
    end
  end
end

local function getLiveListingValue(listing)
  if not listing or not listing.id then
    return nil
  end
  if listing.rtBiz then
    return tonumber(listing.marketValue) or tonumber(listing.value)
  end
  return career_modules_valueCalculator.getInventoryVehicleSellValue(listing.id)
end

local function scheduleNextOffer(listing, timeNow)
  local multiplier = listing.offerTimeMultiplier or 1
  listing.timeOfNextOffer = timeNow + (TIME_BETWEEN_OFFERS_BASE * multiplier) + (math.random(-60, 60) / 100 * TIME_BETWEEN_OFFERS_BASE * multiplier)
end

-- Forward decls: listVehicles / addVehicleListing need these before their definitions below.
local listingNeedsRepair
local syncSpawnedListingPartConditions
local listingDamagedAfterListing

local function addVehicleListing(entry, timestamp)
  local inventoryId = entry.inventoryId
  local customValue = entry.value
  local veh = career_modules_inventory.getVehicles()[inventoryId]
  if not veh or findVehicleListing(inventoryId) then
    return false
  end

  -- Snapshot repair state at list time. Damaged cars may still be listed (at a lower
  -- value); accept is only blocked when the car becomes damaged *after* listing.
  local needsRepairAtListing = listingNeedsRepair(inventoryId)

  local value = customValue or career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  local marketValue = career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  local marketRatio = tonumber(value) / marketRatioDenominator(marketValue)

  local offerTimeMultiplier = offerTimeMultiplierForRatio(marketRatio)

  local listingData = {
    id = veh.id,
    timestamp = timestamp,
    offers = {},
    value = value,
    marketValue = marketValue,
    marketValueAtListing = marketValue,
    needsRepairAtListing = needsRepairAtListing,
    isManualValue = customValue ~= nil,
    marketRatio = marketRatio,
    timeOfNextOffer = nil,
    offerTimeMultiplier = offerTimeMultiplier,
    source = entry.source,
    temporary = entry.temporary == true,
    niceName = veh.niceName,
    thumbnail = career_modules_inventory.getVehicleThumbnail(inventoryId),
  }
  if entry.offerTimeMultiplier then
    listingData.offerTimeMultiplier = entry.offerTimeMultiplier
  end
  scheduleNextOffer(listingData, timestamp)
  table.insert(listedVehicles, listingData)
  return true
end

local function listVehicles(vehicles, requestId)
  local timestamp = os.time()
  local remaining = 0
  local listedAny = false
  local listedIds = {}

  local function finishAll()
    guihooks.trigger("marketplaceListingsUpdated", getListings())
    guihooks.trigger("marketplaceListVehiclesFinished", {
      ok = listedAny,
      listedIds = listedIds,
      requestId = requestId,
    })
  end

  if type(vehicles) ~= "table" or #vehicles == 0 then
    finishAll()
    return false
  end

  remaining = #vehicles
  for _, entry in ipairs(vehicles) do
    local inventoryId = entry.inventoryId
    local function finishList()
      if addVehicleListing(entry, timestamp) then
        listedAny = true
        table.insert(listedIds, inventoryId)
      end
      remaining = remaining - 1
      if remaining <= 0 then
        finishAll()
      end
    end
    -- syncSpawnedListingPartConditions calls finishList itself when it returns false
    -- (not spawned / nothing to sync). Only wait when it returns true (async pull).
    if not syncSpawnedListingPartConditions(inventoryId, finishList) then
      -- finishList already ran
    end
  end
  return listedAny
end

local function removeVehicleListing(inventoryId)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId or tostring(listing.id) == tostring(inventoryId) then
      table.remove(listedVehicles, i)
      break
    end
  end
end

local function updateListingValue(inventoryId, value)
  local listing = findVehicleListing(inventoryId)
  if not listing then
    return false
  end
  local rounded = roundListingPrice(value)
  if not rounded then
    return false
  end
  refreshLiveListingValues(listing)
  local marketValue = tonumber(getLiveListingValue(listing)) or tonumber(listing.marketValue) or 0
  listing.value = rounded
  listing.isManualValue = true
  listing.marketRatio = rounded / marketRatioDenominator(marketValue)
  listing.offerTimeMultiplier = offerTimeMultiplierForRatio(listing.marketRatio)
  scheduleNextOffer(listing, os.time())
  guihooks.trigger("marketplaceListingsUpdated", getListings())
  return true
end

local function addRtListing(businessId, vehicleId, askVal)
  if not businessId or vehicleId == nil then
    return false
  end
  local bid = tonumber(businessId) or businessId
  local vid = tonumber(vehicleId) or vehicleId
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getVehicleById then
    return false
  end
  local veh = inv.getVehicleById(bid, vid)
  if not veh then
    return false
  end
  local lid = "rt:" .. tostring(bid) .. ":" .. tostring(vid)
  if findVehicleListing(lid) then
    return false
  end
  local vc = veh.vehicleConfig or {}
  local nm = tostring(vc.model_key or "?") .. " " .. tostring(vc.key or "")
  local ask = tonumber(askVal) or 10000
  local ts = os.time()
  local row = {
    id = lid,
    rtBiz = bid,
    rtVid = vid,
    timestamp = ts,
    offers = {},
    value = ask,
    marketValue = ask,
    marketValueAtListing = ask,
    isManualValue = true,
    marketRatio = 1,
    niceName = nm,
    thumbnail = "/ui/images/appDefault.png",
    timeOfNextOffer = nil,
    offerTimeMultiplier = 1
  }
  scheduleNextOffer(row, ts)
  table.insert(listedVehicles, row)
  if offerMenuOpen then
    guihooks.trigger("marketplaceListingsUpdated", getListings())
  end
  return true
end

local function generatePersonality(buyer, _archetypes)
  local data = jsonReadFile("levels/west_coast_usa/facilities/negotiationPersonalities.json")
  if not data then return end

  local archetypeKeys = _archetypes or (buyer and data.randomBuyerArchetypes or data.randomSellerArchetypes)
  if #archetypeKeys == 0 then return end

  local chosenKey = archetypeKeys[math.random(1, #archetypeKeys)]
  local chosenArchetype = data.archetypes[chosenKey] or {}

  local delayRange
  local name
  if chosenArchetype.isDealership then
    name = chosenArchetype.names[math.random(1, #chosenArchetype.names)]
  else
    name = M.firstNames[math.random(1, M.firstNameCount)] -- first name
    if math.random() < 0.01 then
      if math.random() < 0.5 then
        name = name .. " " .. M.initials[math.random(1, M.initialCount)] -- low chance of adding an initial
      else
        name = name .. "-" .. M.firstNames[math.random(1, M.firstNameCount)] -- low chance of adding a hyphen and a new first name
      end
    end
    name = name .. " " .. M.initials[math.random(1, M.initialCount)] .. "." -- add an initial for the last name and a period
  end


  local dr = chosenArchetype.delayRange
  if type(dr) == "table" and dr[1] and dr[2] then
    delayRange = { min = dr[1], max = dr[2] }
  end
  delayRange = delayRange or { min = 3, max = 4 }


  local priceMultiplier
  if buyer then
    priceMultiplier = 1 - (chosenArchetype.priceMultiplier or 0.1)
  else
    priceMultiplier = 1 + (chosenArchetype.priceMultiplier or 0.1)
  end

  return {
    archetype = chosenKey,
    counterOfferReadiness = chosenArchetype.counterOfferReadiness or 0.5,
    offerAcceptanceThreshold = chosenArchetype.offerAcceptanceThreshold or 0.1,
    unpredictability = chosenArchetype.unpredictability or 0.02,
    priceMultiplier = priceMultiplier,
    delayRange = delayRange,
    name = name,
    quotesByPriceTier = chosenArchetype.quotesByPriceTier,

    -- dealership specific negotiation parameters
    isDealership = chosenArchetype.isDealership,
    minimumOverMarket = chosenArchetype.minimumOverMarket,
    desperation = chosenArchetype.desperation,
    desperationMaxDiscount = chosenArchetype.desperationMaxDiscount,
    insultThresholdBase = chosenArchetype.insultThresholdBase,
    insultThresholdVariance = chosenArchetype.insultThresholdVariance,
    insultQuotes = chosenArchetype.insultQuotes,
    happyQuotes = chosenArchetype.happyQuotes,
    startingPatience = chosenArchetype.startingPatience,
    patienceVariance = chosenArchetype.patienceVariance
  }
end

local function generateOfferId()
  local offerId = 0
  ::continueNewOfferId::
  offerId = math.floor(math.random() * 1000000)
  for _, listing in ipairs(listedVehicles) do
    for _, offer in ipairs(listing.offers) do
      if offer.id == offerId then
        goto continueNewOfferId
      end
    end
  end
  return offerId
end

-- Resolve by stable offer id: listing.offers order can change while a spawned-vehicle
-- part-condition sync is in flight, so an index captured before sync can point at the wrong offer.
local function findOfferById(offerId)
  for _, listing in ipairs(listedVehicles) do
    for offerIndex, offer in ipairs(listing.offers) do
      if offer.id == offerId then
        return listing, offerIndex, offer
      end
    end
  end
end

local function generateOffer(inventoryId)
  local listing = inventoryId and findVehicleListing(inventoryId) or listedVehicles[math.random(1, #listedVehicles)]
  if not listing then
    return nil
  end
  refreshLiveListingValues(listing)
  local buyerPersonality = generatePersonality(true)
  if not buyerPersonality then
    return nil
  end
  local listingMarketValue = tonumber(getLiveListingValue(listing))
  if not listingMarketValue then
    listingMarketValue = tonumber(listing.marketValue) or 0
  end
  local marketRatio = tonumber(listing.value) / marketRatioDenominator(listingMarketValue)
  local baseOffer = listingMarketValue

  local personalityMult = buyerPersonality.priceMultiplier or 1.0
  local noise = (biasGainFun(math.random(), 0.5, 0.03) * 0.5) + 0.73
  local finalOfferValue = baseOffer * personalityMult * noise

  if marketRatio < 0.9 then
    local cap = listing.value * (1.05 + (math.random() * 0.1))
    finalOfferValue = math.min(finalOfferValue, cap)
  elseif marketRatio > 1.1 then
    local cap = listingMarketValue * (0.95 + (math.random() * 0.1))
    finalOfferValue = math.min(finalOfferValue, cap)
  end

  local offer = {
    id = generateOfferId(),
    timestamp = os.time(),
    value = math.max(50, math.floor((finalOfferValue + 25) / 50) * 50),
    ttl = OFFER_TTL + ((math.random() * OFFER_TTL_VARIANCE * 2) - OFFER_TTL_VARIANCE) * OFFER_TTL,
    negotiationPossible = not listing.rtBiz,
    buyerPersonality = buyerPersonality,
    -- picked once at generation so the offers inbox shows a stable pitch per buyer
    quote = selectQuoteForPersonality(buyerPersonality, listing.value, true),
    archetype = buyerPersonality.archetype
  }
  table.insert(listing.offers, offer)
  return offer
end

-- Repair state helpers. Damaged cars can be listed/sold at a reduced value; the only
-- hard block is accepting an offer after the car was damaged *after* it was listed.
listingNeedsRepair = function(inventoryId)
  if type(inventoryId) ~= "number" then return false end
  local insurance = career_modules_insurance_insurance
  if not (insurance and insurance.inventoryVehNeedsRepair) then return false end
  return insurance.inventoryVehNeedsRepair(inventoryId) and true or false
end

listingDamagedAfterListing = function(listing, inventoryId)
  if not listing or listing.rtBiz then return false end
  local id = inventoryId or listing.id
  local needsRepair = listingNeedsRepair(id)
  if not needsRepair then
    -- Listed damaged, then repaired: later crashes must still block accept/negotiate.
    -- getListings() calls this on a deepcopy; write the flag on the live listing too.
    if listing.needsRepairAtListing then
      listing.repairedSinceListing = true
      local live = findVehicleListing(id)
      if live then
        live.repairedSinceListing = true
      end
    end
    return false
  end
  if listing.needsRepairAtListing and not listing.repairedSinceListing then
    return false -- still the original pre-list damage
  end
  return true
end

local function refuseSaleDamagedAfterListing()
  guihooks.trigger("toastrMsg", {
    type = "warning",
    title = "Repair required",
    msg = "This vehicle was damaged after listing. Repair it before accepting offers."
  })
end

-- Crash damage lives on the spawned vehicle until part conditions are pulled into inventory.
-- Without this, listingNeedsRepair / VALUE_LOSS_LIMIT still see the pre-crash snapshot.
local listingPartSyncInFlight = {}
syncSpawnedListingPartConditions = function(inventoryId, onDone)
  if type(inventoryId) ~= "number" then
    if onDone then onDone() end
    return false
  end
  if listingPartSyncInFlight[inventoryId] then
    if onDone then
      table.insert(listingPartSyncInFlight[inventoryId], onDone)
    end
    return true
  end
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId
    and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then
    if onDone then onDone() end
    return false
  end
  local veh = getObjectByID(vehId)
  if not veh then
    if onDone then onDone() end
    return false
  end
  listingPartSyncInFlight[inventoryId] = { onDone }
  core_vehicleBridge.requestValue(veh, function(res)
    local callbacks = listingPartSyncInFlight[inventoryId] or {}
    listingPartSyncInFlight[inventoryId] = nil
    if res and res.result and career_modules_inventory.getPartConditionsCallback then
      career_modules_inventory.getPartConditionsCallback(res.result, inventoryId)
    end
    for _, cb in ipairs(callbacks) do
      if cb then cb() end
    end
  end, 'getPartConditions')
  return true
end

-- Completes the sale after repair checks. Returns true only when the vehicle changed hands.
-- Optional saleValue is the negotiated payout; when omitted, the stored offer.value is used.
-- Do not mutate offer.value before this succeeds — a repair refusal must leave the offer intact.
local function completeAcceptOffer(inventoryId, offerIndex, saleValue)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      local offer = listing.offers[offerIndex]
      if not offer then
        return false
      end
      local payout = tonumber(saleValue)
      if payout == nil then
        payout = tonumber(offer.value) or 0
      end
      table.remove(listing.offers, offerIndex)
      if listing.rtBiz then
        local bank = career_modules_bank
        local acct = bank and bank.getBusinessAccount and bank.getBusinessAccount("racingTeam", listing.rtBiz)
        local accountId = acct and (acct.id or acct.accountId)
        if bank and bank.rewardToAccount and accountId then
          bank.rewardToAccount({
            money = { amount = payout }
          }, accountId, "Vehicle sale", "Marketplace")
        end
        if career_modules_business_businessInventory and career_modules_business_businessInventory.removeVehicle then
          career_modules_business_businessInventory.removeVehicle(listing.rtBiz, listing.rtVid)
        end
        table.remove(listedVehicles, i)
      else
        if career_modules_carmeets and career_modules_carmeets.onMarketplaceVehicleSold then
          local marketValue = tonumber(getLiveListingValue(listing)) or tonumber(listing.marketValue) or tonumber(listing.value) or 0
          career_modules_carmeets.onMarketplaceVehicleSold(inventoryId, payout, marketValue)
        end
        career_modules_inventory.sellVehicle(inventoryId, payout)
      end
      return true
    end
  end
  return false
end

local function tryAcceptOfferAfterSync(inventoryId, offerId, saleValue)
  if offerId == nil then return false end
  local listing, offerIndex = findOfferById(offerId)
  if not listing or listing.id ~= inventoryId or not offerIndex then
    return false
  end
  if not listing.rtBiz and listingDamagedAfterListing(listing, inventoryId) then
    refuseSaleDamagedAfterListing()
    guihooks.trigger("marketplaceListingsUpdated", getListings())
    return false
  end
  local ok = completeAcceptOffer(inventoryId, offerIndex, saleValue)
  guihooks.trigger("marketplaceListingsUpdated", getListings())
  return ok
end

-- Prevent double-accept while a spawned listing's part-condition sync is still running.
local acceptInFlight = {}

-- Returns true when the sale completed, or when a spawned-vehicle sync was started (sale may
-- still be refused after live part conditions arrive). False means the offer could not be taken.
-- Optional saleValue is passed through after sync so negotiated price is applied only on success.
local function acceptOffer(inventoryId, offerIndex, saleValue)
  local listing = findVehicleListing(inventoryId)
  if not listing then return false end
  local offer = listing.offers[offerIndex]
  if not offer then return false end
  if acceptInFlight[inventoryId] then return false end
  local offerId = offer.id
  if listing.rtBiz then
    local ok = completeAcceptOffer(inventoryId, offerIndex, saleValue)
    if ok then
      guihooks.trigger("marketplaceListingsUpdated", getListings())
    end
    return ok
  end
  acceptInFlight[inventoryId] = true
  if syncSpawnedListingPartConditions(inventoryId, function()
    tryAcceptOfferAfterSync(inventoryId, offerId, saleValue)
    acceptInFlight[inventoryId] = nil
  end) then
    return true
  end
  acceptInFlight[inventoryId] = nil
  return tryAcceptOfferAfterSync(inventoryId, offerId, saleValue)
end

local function deleteOffer(inventoryId, offerIndex)
  for i, listing in ipairs(listedVehicles) do
    if listing.id == inventoryId then
      table.remove(listing.offers, offerIndex)
      return true
    end
  end
  return false
end

-- getListings() reverses offers and pushes disabled ones to the end before the UI sees them, so a
-- row index from the phone does not line up with listing.offers here. Offers also expire on a
-- timer while a confirmation dialog is open. Resolve by the offer's stable id at call time so an
-- accept or decline can never land on a different offer than the one the player tapped.
local function acceptOfferById(offerId)
  local listing, offerIndex = findOfferById(offerId)
  if not listing then return false end
  return acceptOffer(listing.id, offerIndex) and true or false
end

local function declineOfferById(offerId)
  local listing, offerIndex = findOfferById(offerId)
  if not listing then return false end
  return deleteOffer(listing.id, offerIndex) and true or false
end

local function getOfferCount()
  local count = 0
  for _, listing in ipairs(listedVehicles) do
    count = count + #listing.offers
  end
  return count
end

local function generateNewOffers()
  local timeNow = os.time()
  local offerCountDiff = 0

  for _, listing in ipairs(listedVehicles) do
    if not listing.timeOfNextOffer then
      local multiplier = listing.offerTimeMultiplier or 1
      listing.timeOfNextOffer = timeNow + (TIME_BETWEEN_OFFERS_BASE * multiplier) + (math.random(-60, 60) / 100 * TIME_BETWEEN_OFFERS_BASE * multiplier)
    end

    if timeNow >= listing.timeOfNextOffer then
      listing.timeOfNextOffer = nil
      local offer = generateOffer(listing.id)
      if offer then
        local offerValue = offer.value
        local standout = isStandoutOffer(listing, offerValue)
        listing.bestOfferValue = math.max(tonumber(listing.bestOfferValue) or 0, offerValue)

        if detailedOfferBannersShown < DETAILED_OFFER_BANNER_LIMIT or standout then
          local delta = offerValue - listing.value
          local deltaSign = delta >= 0 and "+ " or "- "
          local title = standout and detailedOfferBannersShown >= DETAILED_OFFER_BANNER_LIMIT and "Strong Offer" or "New Offer"
          fireMarketplacePhoneNotification(
            "marketplace.newOffer",
            title,
            core_locales.translateWithOrWithoutContext(listing.niceName),
            "$" .. string.format("%.2f", offerValue) .. " (" .. deltaSign .. string.format("%.2f", math.abs(delta)) .. "$)",
            "invite",
            { ttl = DETAILED_OFFER_TTL }
          )
          if detailedOfferBannersShown < DETAILED_OFFER_BANNER_LIMIT then
            detailedOfferBannersShown = detailedOfferBannersShown + 1
          end
        else
          local pendingCount = countPendingOffers()
          local waitingLabel = pendingCount == 1 and "You have 1 offer waiting" or ("You have " .. pendingCount .. " offers waiting")
          fireMarketplacePhoneNotification(
            "marketplace.newOffer",
            "Marketplace",
            waitingLabel,
            nil,
            "invite",
            {
              ttl = DIGEST_OFFER_TTL,
              forceTtl = true,
              replaceKey = DIGEST_REPLACE_KEY,
              sound = digestBannerActive and false or PHONE_NOTIF_SOUND,
            }
          )
          digestBannerActive = true
        end
        offerCountDiff = offerCountDiff + 1
      end
    end

    local expiredOffersCount = 0
    for offerIndex = #listing.offers, 1, -1 do
      local offer = listing.offers[offerIndex]
      if not offer.expiredViewCounter and timeNow - offer.timestamp > (offer.ttl or OFFER_TTL) then
        offer.expiredViewCounter = 0
        offerCountDiff = offerCountDiff - 1
      end

      if offer.expiredViewCounter then
        expiredOffersCount = expiredOffersCount + 1
        if expiredOffersCount > MAXIMUM_EXPIRED_OFFERS then
          table.remove(listing.offers, offerIndex)
        end
      end
    end
  end

  if offerMenuOpen and offerCountDiff ~= 0 then
    guihooks.trigger("marketplaceListingsUpdated", getListings())
  end

  return offerCountDiff
end

local negotiationActive = false
local startingPrice
local patience = 1
local isInsulted = false
local myOffer
local theirOffer
local offerHistory = {}
local amISelling
local negotiationStatus
local vehicleNiceName
local vehicleThumbnail
local vehicleMileage
local actualVehicleValue
local vehicleHideMarketValue = false
local vehiclePlayerStartsNegotiation = false
local vehicleHasVisibleTheirOffer = false
local isDesperate = false
local insultThreshold = 0.75
local opponentQuote = ""

local negotiationInventoryId
local negotiationOfferIndex
local negotiationCarMeetOfferIndex
local negotiationMaxBuyerPrice = math.huge

local shopId
local opponentPersonality
local purchaseFailureReason
local saleCompleted = false
local phoneMarketplaceUiOpen = false
local negotiationReturnRoute = "play"
local negotiationReturnParams = {}

local function captureNegotiationReturnRoute(fallbackRoute)
  local routeName = fallbackRoute or "play"
  local routeParams = {}
  local router = extensions and extensions.ui_router
  local current = router and router.getCurrent and router.getCurrent() or nil
  local request = current and current.request or nil
  if request and type(request.name) == "string" and request.name ~= "" and request.name ~= "career.negotiation" then
    routeName = request.name
    routeParams = deepcopy(request.params or {})
  end
  negotiationReturnRoute = routeName
  negotiationReturnParams = routeParams
end

local function setPhoneMarketplaceUiOpen(open)
  phoneMarketplaceUiOpen = open and true or false
  if career_modules_vehicleShopping and career_modules_vehicleShopping.setShoppingUiOpen then
    career_modules_vehicleShopping.setShoppingUiOpen(phoneMarketplaceUiOpen)
  end
end

local function getNegotiationState()
  local negotiationVehicleInfo = shopId and career_modules_vehicleShopping.getVehicleInfoByShopId(shopId) or nil
  return {
    active = negotiationActive,
    amISelling = amISelling,
    startingPrice = startingPrice,
    patience = patience,
    myOffer = myOffer,
    theirOffer = theirOffer,
    status = negotiationStatus,
    opponentName = opponentPersonality and _tr(opponentPersonality.name) or "",
    -- archetype quotes are locale keys, so translate here like the name above
    opponentQuote = opponentQuote and _tr(opponentQuote) or "",
    vehicleNiceName = vehicleNiceName,
    vehicleThumbnail = vehicleThumbnail,
    vehicleMileage = vehicleMileage,
    actualVehicleValue = vehicleHideMarketValue and nil or actualVehicleValue,
    hideMarketValue = vehicleHideMarketValue == true,
    playerStartsNegotiation = vehiclePlayerStartsNegotiation == true,
    hasVisibleTheirOffer = vehicleHasVisibleTheirOffer == true,
    purchaseAfterAccept = not amISelling and negotiationVehicleInfo and negotiationVehicleInfo.source == "carMeet",
    purchaseFailureReason = purchaseFailureReason,
    saleCompleted = saleCompleted == true,
    negotiationStatus = negotiationStatus,
    offerHistory = offerHistory,
    returnRoute = negotiationReturnRoute,
    returnParams = negotiationReturnParams
  }
end

-- Whether the negotiation currently running was opened by the phone. Set per negotiation by
-- the caller rather than read from phoneMarketplaceUiOpen: that flag is only cleared when the
-- phone's Vue components unmount, so a phone closed any other way (closeAllMenus, a game state
-- change) left it stuck true. A later computer-initiated negotiation then took the phone branch,
-- never fired ChangeState, and the garage computer sat on a screen that never arrived.
local negotiationFromPhone = false

local function openNegotiationUi()
  if negotiationFromPhone then
    guihooks.trigger('negotiationData', getNegotiationState())
  else
    captureNegotiationReturnRoute("career.computer.vehicleShopping")
    guihooks.trigger('ChangeState', {state = 'career.negotiation', params = {}})
  end
end

selectQuoteForPersonality = function(personality, vehicleValue, isBuyer)
  if not personality then
    return ""
  end

  local priceTier = "low"
  if personality.priceTierThresholds then
    if vehicleValue >= personality.priceTierThresholds.mid then
      priceTier = "high"
    elseif vehicleValue >= personality.priceTierThresholds.low then
      priceTier = "mid"
    end
  else
    if vehicleValue >= 15000 then
      priceTier = "high"
    elseif vehicleValue >= 5000 then
      priceTier = "mid"
    end
  end

  local quotes = personality.quotesByPriceTier and personality.quotesByPriceTier[priceTier]
  if not isBuyer and not personality.isDealership then
    quotes = M.privateSellerQuotes
  end
  if isBuyer and personality.isDealership then
    quotes = M.dealershipBuyerQuotes
  end
  if not quotes and not isBuyer and personality.isDealership then
    quotes = {
      "We're here to work with you on this vehicle.",
      "Let me see what I can do for you.",
      "I think we can find a price that works for both of us.",
      "We want to make this work for you.",
      "Let's see if we can reach an agreement."
    }
  end
  if quotes and #quotes > 0 then
    return quotes[math.random(1, #quotes)]
  end
  return isBuyer and "I'm interested in this vehicle." or "Thanks for your interest."
end

local beginNegotiateBuyingOffer

local function startNegotiateBuyingOffer(inventoryId, offerIndex, fromPhone)
  negotiationFromPhone = fromPhone == true
  saleCompleted = false
  local listing = findVehicleListing(inventoryId)
  if listing and listing.rtBiz then
    return
  end
  refreshLiveListingValues(listing)
  local offer = listing and listing.offers[offerIndex]
  if not listing or not offer then
    return
  end

  local function continueNegotiate()
    listing = findVehicleListing(inventoryId)
    offer = listing and listing.offers[offerIndex]
    if not listing or not offer then
      return
    end
    -- Sync may reveal post-list crash damage; keep negotiation closed when so.
    if listingDamagedAfterListing(listing, inventoryId) then
      guihooks.trigger("toastrMsg", {
        type = "warning",
        title = "Repair required",
        msg = "This vehicle was damaged after listing. Repair it before accepting offers."
      })
      return
    end
    beginNegotiateBuyingOffer(listing, offer, inventoryId, offerIndex)
  end

  if syncSpawnedListingPartConditions(inventoryId, continueNegotiate) then
    return
  end
  continueNegotiate()
end

beginNegotiateBuyingOffer = function(listing, offer, inventoryId, offerIndex)
  local buyerPersonality = offer.buyerPersonality

  opponentPersonality = buyerPersonality
  if opponentPersonality.isDealership then
    local desperation = opponentPersonality.desperation or 0.15
    isDesperate = math.random() < desperation

    local baseThreshold = opponentPersonality.insultThresholdBase or 0.75
    local variance = opponentPersonality.insultThresholdVariance or 0.05
    insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
  else
    isDesperate = false
    insultThreshold = 0.75
  end
  opponentQuote = selectQuoteForPersonality(opponentPersonality, listing.value, true)

  negotiationInventoryId = inventoryId
  negotiationOfferIndex = offerIndex
  negotiationCarMeetOfferIndex = nil
  vehicleNiceName = core_locales.translateWithOrWithoutContext(listing.niceName)
  vehicleThumbnail = listing.thumbnail
  vehicleMileage = career_modules_valueCalculator.getVehicleMileageById(inventoryId)
  actualVehicleValue = career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  vehicleHideMarketValue = false
  vehiclePlayerStartsNegotiation = false
  vehicleHasVisibleTheirOffer = true
  negotiationMaxBuyerPrice = math.max(50,
    (tonumber(actualVehicleValue) or 0) * 1.25,
    (tonumber(offer.value) or 0) * 1.5)
  startingPrice = listing.value
  negotiationActive = true
  patience = 1
  isInsulted = false
  theirOffer = offer.value
  myOffer = listing.value
  amISelling = true
  negotiationStatus = "initial"
  offerHistory = {
    {
      myOffer = startingPrice,
      negotiationStatus = "initial"
    },
    {
      theirOffer = offer.value,
      negotiationStatus = "initial"
    }
  }

  openNegotiationUi()
end

local function startNegotiateBuyingOfferById(offerId, fromPhone)
  local listing, offerIndex = findOfferById(offerId)
  if not listing then return false end
  startNegotiateBuyingOffer(listing.id, offerIndex, fromPhone)
  return true
end

local function startCarMeetBuyingOffer(listing, offer, offerIndex)
  negotiationFromPhone = false
  if not listing or not offer then return false end
  local buyerPersonality = offer.buyerPersonality or generatePersonality(true)
  if not buyerPersonality then return false end

  opponentPersonality = buyerPersonality
  if opponentPersonality.isDealership then
    local desperation = opponentPersonality.desperation or 0.15
    isDesperate = math.random() < desperation

    local baseThreshold = opponentPersonality.insultThresholdBase or 0.75
    local variance = opponentPersonality.insultThresholdVariance or 0.05
    insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
  else
    isDesperate = false
    insultThreshold = 0.75
  end
  opponentQuote = selectQuoteForPersonality(opponentPersonality, listing.value or listing.marketValue or 0, true)

  negotiationInventoryId = listing.inventoryId
  negotiationOfferIndex = nil
  negotiationCarMeetOfferIndex = tonumber(offerIndex)
  vehicleNiceName = listing.niceName
  vehicleThumbnail = listing.thumbnail
  vehicleMileage = career_modules_valueCalculator.getVehicleMileageById(listing.inventoryId)
  actualVehicleValue = tonumber(listing.marketValue) or career_modules_valueCalculator.getInventoryVehicleSellValue(listing.inventoryId)
  vehicleHideMarketValue = false
  vehiclePlayerStartsNegotiation = false
  vehicleHasVisibleTheirOffer = true
  negotiationMaxBuyerPrice = math.max(50,
    (tonumber(actualVehicleValue) or 0) * 1.25,
    (tonumber(offer.value) or 0) * 1.5)
  startingPrice = tonumber(listing.value) or tonumber(actualVehicleValue) or tonumber(offer.value) or 0
  negotiationActive = true
  patience = 1
  isInsulted = false
  theirOffer = tonumber(offer.value) or startingPrice
  myOffer = startingPrice
  amISelling = true
  negotiationStatus = "initial"
  offerHistory = {
    {
      myOffer = startingPrice,
      negotiationStatus = "initial"
    },
    {
      theirOffer = theirOffer,
      negotiationStatus = "initial"
    }
  }

  captureNegotiationReturnRoute("carMeetOffers")
  guihooks.trigger('ChangeState', {state = 'career.negotiation', params = {}})
  return true
end

-- returns true when a negotiation actually opened, so callers (the phone) know whether to
-- navigate to their negotiate screen
local function startNegotiateSellingOffer(_shopId, fromPhone)
  negotiationFromPhone = fromPhone == true
  shopId = _shopId
  purchaseFailureReason = nil
  saleCompleted = false
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return false end
  if vehicleInfo.source == "carMeet" and career_modules_vehicleShopping and career_modules_vehicleShopping.canPurchaseCarMeetVehicle then
    if not career_modules_vehicleShopping.canPurchaseCarMeetVehicle(true) then
      return false
    end
  end
  if (vehicleInfo.discountPercentage or 0) > 0 or vehicleInfo.negotiationPossible == false then
    guihooks.trigger("toastrMsg", {
      type = "warning",
      title = "Negotiation unavailable",
      msg = vehicleInfo.negotiationDisabledReason or "This vehicle cannot be negotiated."
    })
    return false
  end
  local sellerPersonality = vehicleInfo.negotiationPersonality

  opponentPersonality = sellerPersonality
  if opponentPersonality.isDealership then
    local desperation = opponentPersonality.desperation or 0.15
    isDesperate = math.random() < desperation

    local baseThreshold = opponentPersonality.insultThresholdBase or 0.75
    local variance = opponentPersonality.insultThresholdVariance or 0.05
    insultThreshold = baseThreshold + (math.random() * variance * 2 - variance)
  else
    isDesperate = false
    insultThreshold = 0.75
  end
  local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  local valueBase = vehicleInfo.valueBase or (vehicleInfo.marketValue and vehicleInfo.marketValue * (vehicleInfo.negotiationPersonality and vehicleInfo.negotiationPersonality.priceMultiplier or 1)) or vehicleInfo.Value
  local roundedVehicleValue = math.floor((valueBase or vehicleInfo.Value or 0) * vehicleBuyMult + 0.5)
  opponentQuote = selectQuoteForPersonality(opponentPersonality, roundedVehicleValue, false)

  negotiationInventoryId = nil
  negotiationOfferIndex = nil
  negotiationCarMeetOfferIndex = nil
  negotiationMaxBuyerPrice = math.huge
  vehicleNiceName = vehicleInfo.Name
  vehicleThumbnail = vehicleInfo.preview
  vehicleMileage = vehicleInfo.Mileage
  local marketValueBase = vehicleInfo.marketValueBase or vehicleInfo.marketValue or valueBase
  actualVehicleValue = math.floor((marketValueBase or roundedVehicleValue) * vehicleBuyMult + 0.5)
  startingPrice = roundedVehicleValue
  vehicleHideMarketValue = vehicleInfo.hideMarketValue == true
  vehiclePlayerStartsNegotiation = vehicleInfo.playerStartsNegotiation == true
  vehicleHasVisibleTheirOffer = not vehiclePlayerStartsNegotiation

  negotiationActive = true

  if (vehicleInfo.discountPercentage or 0) > 0 then
    startingPrice = startingPrice * (1 - vehicleInfo.discountPercentage / 100)
  end

  theirOffer = startingPrice
  isInsulted = false
  myOffer = nil
  amISelling = false
  negotiationStatus = "initial"
  offerHistory = vehiclePlayerStartsNegotiation and {} or {
    {
      theirOffer = startingPrice,
      negotiationStatus = negotiationStatus
    }
  }

  local basePatience = opponentPersonality.startingPatience or 1.0
  local patienceVariance = opponentPersonality.patienceVariance or 0.1
  patience = math.max(0.2, math.min(1.0, basePatience + (math.random() * patienceVariance * 2 - patienceVariance)))

  -- when the phone marketplace is driving this, it opens its own negotiate screen
  if negotiationFromPhone then
    guihooks.trigger('negotiationData', getNegotiationState())
  else
    captureNegotiationReturnRoute("career.computer.vehicleShopping.vehicles")
    guihooks.trigger('ChangeState', {state = 'career.negotiation', params = {}})
  end
  return true
end

local function dismissNegotiation()
  negotiationFromPhone = false
  negotiationActive = false
  purchaseFailureReason = nil
  saleCompleted = false
  negotiationCarMeetOfferIndex = nil
  myOffer = nil
end

local function cancelNegotiation()
  negotiationFromPhone = false
  negotiationActive = false
  negotiationStatus = "failed"
  purchaseFailureReason = nil
  saleCompleted = false

  if myOffer then
    if amISelling then
      if negotiationCarMeetOfferIndex and career_modules_carmeets and career_modules_carmeets.disableCarMeetOfferNegotiation then
        career_modules_carmeets.disableCarMeetOfferNegotiation(negotiationCarMeetOfferIndex)
      else
        local listing = findVehicleListing(negotiationInventoryId)
        if listing and listing.offers and listing.offers[negotiationOfferIndex] then
          listing.offers[negotiationOfferIndex].negotiationPossible = false
        end
      end
    else
      local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
      vehicleInfo.negotiationPossible = false
    end
  end
  negotiationCarMeetOfferIndex = nil
end

local function isOfferAllowed(price)
  if amISelling then
    return price > theirOffer and (not myOffer or price <= myOffer)
  else
    return (not vehiclePlayerStartsNegotiation or vehicleHasVisibleTheirOffer or price >= 0) and (not vehicleHasVisibleTheirOffer or price < theirOffer) and price >= (myOffer or 0)
  end
end

local function calculatePatienceDrop(baseValue)
  local patienceDrop = 0

  if not amISelling and (tonumber(myOffer) or 0) >= (tonumber(baseValue) or 0) then
    return 0
  end

  if amISelling then
    local theirOfferAmount = theirOffer or baseValue
    local gapFromTheirOffer = math.abs(myOffer - theirOfferAmount)
    local gapFromMarket = math.abs(myOffer - baseValue)
    local referenceGap = opponentPersonality.isDealership and gapFromTheirOffer or gapFromMarket
    local referenceValue = opponentPersonality.isDealership and theirOfferAmount or baseValue
    local pctScale = math.max(tonumber(referenceValue) or 0, MIN_RATIO_DENOMINATOR)
    local gapPct = (referenceGap / pctScale) * 100
    local priceScale = math.min(1, pctScale / 1000)
    local percentageWeight = priceScale
    local absoluteWeight = 1 - priceScale

    local percentagePatienceDrop = gapPct * 3
    local absolutePatienceDrop = (referenceGap / 100) * 8
    local dealershipModifier = opponentPersonality.isDealership and 0.6 or 1.0

    patienceDrop = ((percentagePatienceDrop * percentageWeight + absolutePatienceDrop * absoluteWeight) * dealershipModifier) + math.random() * 12

  else
    local theirAskingPrice = theirOffer or baseValue
    local gapFromTheirPrice = math.abs(myOffer - theirAskingPrice)
    local gapFromMarket = math.abs(myOffer - baseValue)

    local referenceGap, referenceValue
    if opponentPersonality.isDealership then

      local insBase = tonumber(baseValue) or 0
      local floorOffer = insBase > 0 and insBase * 0.9 or startingPrice * insultThreshold
      local minimumAcceptableOffer = math.min(startingPrice * insultThreshold, floorOffer)
      if myOffer < minimumAcceptableOffer then
        isInsulted = true
        return 1
      end
      referenceGap = gapFromTheirPrice
      referenceValue = theirAskingPrice
    else
      local baseNum = tonumber(baseValue) or 0
      if baseNum > 0 and myOffer >= baseNum * 0.9 then
        referenceGap = gapFromTheirPrice * 0.5
        referenceValue = theirAskingPrice
      else
        referenceGap = gapFromMarket
        referenceValue = math.max(baseNum, MIN_RATIO_DENOMINATOR)
      end
    end

    local pctScaleBuy = math.max(tonumber(referenceValue) or 0, MIN_RATIO_DENOMINATOR)
    local gapPct = (referenceGap / pctScaleBuy) * 100
    local priceScale = math.min(1, pctScaleBuy / 1000)
    local percentageWeight = priceScale
    local absoluteWeight = 1 - priceScale

    local percentagePatienceDrop = gapPct * 2.5
    local absolutePatienceDrop = (referenceGap / 100) * 6
    local dealershipModifier = opponentPersonality.isDealership and 0.6 or 1.0

    patienceDrop = ((percentagePatienceDrop * percentageWeight + absolutePatienceDrop * absoluteWeight) * dealershipModifier) + math.random() * 10
  end

  return patienceDrop / 100
end

local function generateCounterOffer()
  local diff = theirOffer - myOffer
  local weight = 0.3 + math.random() * 0.4
  if not amISelling and vehiclePlayerStartsNegotiation and not vehicleHasVisibleTheirOffer then
    weight = 0.08 + math.random() * 0.12
  end

  if amISelling then
    local currentBuyerPosition = theirOffer
    local movement = math.abs(diff) * weight
    local result = currentBuyerPosition + movement
    local step = math.max(theirOffer, math.floor(result / 50 + 0.5) * 50)
    return math.min(step, negotiationMaxBuyerPrice)
  else
    local currentSellerPosition = theirOffer
    local movement = math.abs(diff) * weight
    local result = currentSellerPosition - movement
    return math.max(myOffer, math.floor(result / 50 + 0.5) * 50)
  end
end

local function makeOffer(price)
  if not isOfferAllowed(price) then return false end

  if not amISelling then
    local vehicleInfo = shopId and career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
    if vehicleInfo and vehicleInfo.source == "carMeet" and career_modules_vehicleShopping and career_modules_vehicleShopping.canPurchaseCarMeetVehicle then
      if not career_modules_vehicleShopping.canPurchaseCarMeetVehicle(true) then
        return false
      end
    end
  end

  if not amISelling and career_modules_carmeets and career_modules_carmeets.applyLowballPenalty then
    career_modules_carmeets.applyLowballPenalty(price, actualVehicleValue)
  end

  myOffer = price
  table.insert(offerHistory, {
    myOffer = myOffer
  })
  local baseValue = tonumber(actualVehicleValue) or 0

  negotiationStatus = "thinking"
  guihooks.trigger('negotiationData', getNegotiationState())
  core_jobsystem.create(function(job)
    local patienceChange = calculatePatienceDrop(baseValue)
    local thinkingTime = 5.5
    if opponentPersonality.isDealership then
      local marketGap = math.abs(myOffer - baseValue) / math.max(baseValue, MIN_RATIO_DENOMINATOR)
      local askingGap = math.abs(myOffer - startingPrice) / math.max(tonumber(startingPrice) or 0, MIN_RATIO_DENOMINATOR)
      if marketGap < 0.15 and askingGap > 0.20 then
        thinkingTime = 2.5 + math.random() * 1.5
      elseif askingGap > 0.30 then
        thinkingTime = 1.0 + math.random() * 0.8
      elseif marketGap < 0.10 then
        thinkingTime = 2.0 + math.random() * 1.0
      else
        thinkingTime = 1.5 + math.random() * 1.0
      end
    else
      thinkingTime = 2.0 + math.random() * 2.0
    end
    if patience <= 0 then
      thinkingTime = 0.5
    end

    thinkingTime = thinkingTime/2 + 1
    log('I', 'marketplace', string.format('thinking on offer %d for %0.1fs...', myOffer, thinkingTime))

    job.sleep(thinkingTime)
    negotiationStatus = "typing"
    guihooks.trigger('negotiationData', getNegotiationState())
    log('I', 'marketplace', string.format('typing for %0.1fs...', thinkingTime))


    job.sleep(thinkingTime)
    patience = math.max(0, patience - patienceChange)

    if opponentPersonality.isDealership then
      local minimumOverMarket = opponentPersonality.minimumOverMarket or 200
      local desperationMaxDiscount = opponentPersonality.desperationMaxDiscount or 0.35

      local absoluteMinimum = isDesperate and baseValue * (1 - desperationMaxDiscount) or baseValue + minimumOverMarket
      local negotiationRange = startingPrice - absoluteMinimum
      local patienceMultiplier = patience * 0.8
      local willingToNegotiate = negotiationRange * patienceMultiplier
      local minAcceptable = startingPrice - willingToNegotiate
      local theirOfferCandidate

      if not amISelling then
        if isInsulted then
          local insultQuotes = opponentPersonality.insultQuotes
          if insultQuotes and #insultQuotes > 0 then
            opponentQuote = insultQuotes[math.random(1, #insultQuotes)]
          else
            opponentQuote = "That's funny, do you have a real offer?"
          end

        elseif patience <= 0.40 then
          theirOfferCandidate = math.floor(minAcceptable / 50 + 0.5) * 50
        elseif myOffer >= minAcceptable then
          local gapToClose = theirOffer - myOffer
          if gapToClose > 0 then
            local baseMovePercent = (1 - patience) * 0.4 + 0.25
            local movePercent = baseMovePercent + (math.random() * 0.15 - 0.075)
            movePercent = math.max(0.15, math.min(0.75, movePercent))
            local counterAmount = myOffer + (gapToClose * movePercent)
            theirOfferCandidate = math.min(math.max(myOffer, math.floor(counterAmount / 50 + 0.5) * 50), theirOffer)
          else
            theirOfferCandidate = myOffer
          end
        else
          local gapToClose = theirOffer - myOffer
          local baseMovePercent = (1 - patience) * 0.4 + 0.25
          local movePercent = baseMovePercent + (math.random() * 0.15 - 0.075)
          movePercent = math.max(0.15, math.min(0.75, movePercent))
          local counterAmount = myOffer + (gapToClose * movePercent)
          theirOfferCandidate = math.max(minAcceptable, math.floor(counterAmount / 50 + 0.5) * 50)
        end

        if patience <= 0 then
          negotiationStatus = "failed"
          theirOffer = startingPrice
        elseif theirOfferCandidate <= myOffer then
          theirOffer = myOffer
          negotiationStatus = "accepted"

          if myOffer > (minAcceptable * 1.10) then
            local happyQuotes = opponentPersonality.happyQuotes
            if happyQuotes and #happyQuotes > 0 then
              opponentQuote = happyQuotes[math.random(1, #happyQuotes)]
            end
          end
        else
          if theirOfferCandidate >= theirOffer then
            negotiationStatus = "refused"
          else
            theirOffer = theirOfferCandidate
            if patience <= 0.05 then
              negotiationStatus = "counterOfferLastChance"
              opponentQuote = "That's it! Take it or leave it."
            else
              negotiationStatus = "counterOffer"
            end
          end
        end
      else
        local maxAcceptable = math.min(startingPrice * 1.05, negotiationMaxBuyerPrice)

        if patience <= 0.40 then
          theirOfferCandidate = math.floor(maxAcceptable / 50 + 0.5) * 50
        elseif myOffer <= maxAcceptable then
          local gapToClose = myOffer - theirOffer
          local baseMovePercent = (1 - patience) * 0.4 + 0.25
          local movePercent = baseMovePercent + (math.random() * 0.15 - 0.075)
          movePercent = math.max(0.15, math.min(0.75, movePercent))
          local counterAmount = theirOffer + (gapToClose * movePercent)
          theirOfferCandidate = math.min(myOffer, math.floor(counterAmount / 50 + 0.5) * 50, negotiationMaxBuyerPrice)
        else
          local gapToClose = myOffer - theirOffer
          local baseMovePercent = ((1 - patience) * 0.4 + 0.25) * 0.5
          local movePercent = baseMovePercent + (math.random() * 0.1 - 0.05)
          movePercent = math.max(0.10, math.min(0.50, movePercent))
          local counterAmount = theirOffer + (gapToClose * movePercent)
          theirOfferCandidate = math.min(maxAcceptable, math.floor(counterAmount / 50 + 0.5) * 50, negotiationMaxBuyerPrice)
        end

        theirOfferCandidate = math.max(theirOfferCandidate, theirOffer)
        if theirOfferCandidate >= myOffer then
          theirOffer = math.min(myOffer, negotiationMaxBuyerPrice)
          negotiationStatus = "accepted"
        else
          if theirOfferCandidate <= theirOffer then
            negotiationStatus = "refused"
          else
            theirOffer = theirOfferCandidate
            negotiationStatus = "counterOffer"
          end
        end
      end
    else
      if patience <= 0 then
        negotiationStatus = "failed"
      else
        local counter = generateCounterOffer()
        if (not amISelling and counter <= myOffer) or (amISelling and counter >= myOffer) then
          theirOffer = amISelling and math.min(myOffer, negotiationMaxBuyerPrice) or myOffer
          negotiationStatus = "accepted"
        else
          theirOffer = counter
          negotiationStatus = "counterOffer"
        end
      end
    end
    table.insert(offerHistory, { theirOffer = theirOffer, negotiationStatus = negotiationStatus })
    if theirOffer ~= nil then
      vehicleHasVisibleTheirOffer = true
    end
    guihooks.trigger('negotiationData', getNegotiationState())
  end)
  return true
end

local function makeNegotiationOffer(price)
  return makeOffer(tonumber(price))
end

local function notifyCarMeetPurchaseFailure(reason)
  purchaseFailureReason = reason or "Purchase could not be completed."
  -- Purchase blocks (garage space, afford, etc.) are not negotiation failures.
  negotiationStatus = "accepted"
  negotiationActive = true
  ui_message(purchaseFailureReason, 10, "vehicleShopping")
  guihooks.trigger('negotiationData', getNegotiationState())
end

local function takeTheirOffer()
  if amISelling then
    if negotiationCarMeetOfferIndex and career_modules_carmeets and career_modules_carmeets.acceptCarMeetOfferWithValue then
      career_modules_carmeets.acceptCarMeetOfferWithValue(negotiationCarMeetOfferIndex, theirOffer)
      myOffer = nil
      negotiationCarMeetOfferIndex = nil
      purchaseFailureReason = nil
      return {ok = true}
    end

    local listing = findVehicleListing(negotiationInventoryId)
    local offer = listing and listing.offers[negotiationOfferIndex]
    if not offer then
      return {ok = false, reason = "This offer is no longer available."}
    end

    local inventoryId = negotiationInventoryId
    local offerId = offer.id
    local agreedValue = theirOffer

    local function finalizeSellAttempt(ok)
      if ok then
        myOffer = nil
        negotiationCarMeetOfferIndex = nil
        purchaseFailureReason = nil
        saleCompleted = true
      else
        purchaseFailureReason = "This vehicle was damaged after listing. Repair it before accepting offers."
        saleCompleted = false
        ui_message(purchaseFailureReason, 10, "vehicleShopping")
      end
      guihooks.trigger('negotiationData', getNegotiationState())
      saleCompleted = false
    end

    -- Pass agreedValue into the accept path only; do not write offer.value before success,
    -- or a repair refusal leaves the listing with the negotiated price baked in.
    local function doAccept()
      if acceptInFlight[inventoryId] then return false end
      acceptInFlight[inventoryId] = true
      local ok = tryAcceptOfferAfterSync(inventoryId, offerId, agreedValue)
      acceptInFlight[inventoryId] = nil
      return ok
    end

    -- Spawned listings need a live part-condition pull before we can trust post-list damage.
    if syncSpawnedListingPartConditions(inventoryId, function()
      finalizeSellAttempt(doAccept())
    end) then
      return {ok = true, pending = true}
    end

    local ok = doAccept()
    if not ok then
      return {ok = false, reason = "This vehicle was damaged after listing. Repair it before accepting offers."}
    end
    myOffer = nil
    negotiationCarMeetOfferIndex = nil
    purchaseFailureReason = nil
    return {ok = true}
  end

  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    notifyCarMeetPurchaseFailure("This vehicle is no longer available for purchase.")
    return {ok = false, reason = purchaseFailureReason}
  end

  if vehicleInfo.source == "carMeet" then
    if theirOffer < vehicleInfo.Value then
      vehicleInfo.originalSellValue = vehicleInfo.Value
    end
    vehicleInfo.Value = theirOffer
    vehicleInfo.valueBase = theirOffer / career_modules_valueCalculator.getVehicleBuyMarketMultiplier()

    local purchaseOk, purchaseReason = true, nil
    if career_modules_vehicleShopping and career_modules_vehicleShopping.buyCarMeetVehicleNow then
      purchaseOk, purchaseReason = career_modules_vehicleShopping.buyCarMeetVehicleNow(shopId)
    else
      purchaseOk = false
      purchaseReason = "Purchase could not be completed."
    end

    if not purchaseOk then
      notifyCarMeetPurchaseFailure(purchaseReason)
      return {ok = false, reason = purchaseFailureReason}
    end

    if career_modules_carmeets and career_modules_carmeets.addTransactionReputation then
      career_modules_carmeets.addTransactionReputation("buy", theirOffer, actualVehicleValue)
    end
    vehicleInfo.negotiationPossible = false
    myOffer = nil
    negotiationCarMeetOfferIndex = nil
    purchaseFailureReason = nil
    return {ok = true}
  end

  if career_modules_carmeets and career_modules_carmeets.addTransactionReputation then
    career_modules_carmeets.addTransactionReputation("buy", theirOffer, actualVehicleValue)
  end
  if theirOffer < vehicleInfo.Value then
    vehicleInfo.originalSellValue = vehicleInfo.Value
  end
  vehicleInfo.Value = theirOffer
  vehicleInfo.negotiationPossible = false
  vehicleInfo.valueBase = theirOffer / career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  myOffer = nil
  negotiationCarMeetOfferIndex = nil
  purchaseFailureReason = nil
  return {ok = true}
end

-- Completing a negotiated purchase means handing off to the vehicle purchase screen, which is a
-- computer route. takeTheirOffer() only writes the agreed price onto the shop vehicle; without
-- this the phone sent the player back to the browse feed and the car was never actually bought.
-- Close the phone before navigating: opening a computer route underneath an open phone leaves the
-- game in a state neither side owns -- dead computer, "can't open phone while in the menu", no Esc.
local function finishPhonePurchase()
  local purchaseShopId = shopId
  negotiationFromPhone = false
  negotiationActive = false
  if not purchaseShopId then
    return false
  end

  -- Buying from the phone means the player is out in the world, not standing at a dealership, so
  -- drop a route marker on the listing's parking spot. That is where the vehicle is advertised and
  -- where it now actually spawns, so the marker leads to the car they just bought.
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(purchaseShopId)
  local pos = vehicleInfo and vehicleInfo.pos
  if pos and core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  end

  if career_career and career_career.closeAllMenus then
    career_career.closeAllMenus()
  end
  career_modules_vehicleShopping.openPurchaseMenu("instant", purchaseShopId)
  return true
end

-- Marks the listing on the map. The phone stays open so the player can decide about a taxi.
-- No fare is returned: a taxi drives to you and charges for time in the vehicle, so the cost
-- genuinely is not knowable up front. Better to say that than to quote a number that is wrong.
local function routeToListing(_shopId)
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(_shopId)
  local pos = vehicleInfo and vehicleInfo.pos
  if not pos then return {ok = false} end
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  return {
    ok = true,
    distance = core_groundMarkers.getPathLength and core_groundMarkers.getPathLength() or nil,
  }
end

-- Leaves the phone and heads for the listing.
--
-- Must go through navigateToPos: a private listing does not exist in the world until something
-- spawns it. Setting a ground marker alone routed the player to an empty parking spot. navigateToPos
-- starts the inspection, which for sellerId == "private" spawns the vehicle on its own
-- parkingSpotName and leaves the player to drive there.
--
-- wantTaxi hails a real taxi through the vanilla system (gameplay/taxi.lua) rather than
-- quickTravelToVehicle, which teleported the player and skipped the journey. No fare is charged
-- here; vanilla meters its own (initial + perKm + nightSurcharge, per cab model), which is why the
-- price cannot be quoted before the ride.
local function goToListing(_shopId, wantTaxi)
  local vehicleInfo = career_modules_vehicleShopping.getVehicleInfoByShopId(_shopId)
  if not (vehicleInfo and vehicleInfo.pos) then return false end

  if career_career and career_career.closeAllMenus then
    career_career.closeAllMenus()
  end

  -- spawns the listing vehicle and sets the route marker
  career_modules_vehicleShopping.navigateToPos(vehicleInfo.pos, _shopId)

  if wantTaxi then
    local ready = career_modules_playerDriving and career_modules_playerDriving.ensureVanillaTaxiReady
      and career_modules_playerDriving.ensureVanillaTaxiReady()
    if not ready and extensions and extensions.load then
      pcall(extensions.load, "gameplay_taxi")
      ready = career_modules_playerDriving and career_modules_playerDriving.ensureVanillaTaxiReady
        and career_modules_playerDriving.ensureVanillaTaxiReady()
    end
    if ready and gameplay_taxi and gameplay_taxi.callForTaxi then
      -- the inspection fades the screen for ~3s; hail once it has settled
      core_jobsystem.create(function(job)
        job.sleep(3.5)
        if career_modules_playerDriving and career_modules_playerDriving.ensureVanillaTaxiReady then
          career_modules_playerDriving.ensureVanillaTaxiReady()
        end
        if gameplay_taxi and gameplay_taxi.callForTaxi then
          gameplay_taxi.callForTaxi()
        end
      end)
    end
  end
  return true
end

local myOfferValuePtr = im.IntPtr(0)
local timeSinceUpdate = 0
local DEBUG_NEGOTIATION_IMGUI = false
local function onUpdate(dtReal, dtSim, dtRaw)
  if tableIsEmpty(listedVehicles) then
    return
  end

  if negotiationActive and DEBUG_NEGOTIATION_IMGUI then
    im.Begin("Negotiation Buying")
      if negotiationStatus == "thinking" then
        im.Text("Thinking...")
      else
        im.Text("Initial Offer: " .. startingPrice)
        im.Text("Their current Offer: " .. theirOffer)
        im.Text("My current Offer: " .. (myOffer or "(Not set)"))

        myOfferValuePtr[0] = myOffer or startingPrice
        local disabled = myOffer == theirOffer
        if disabled then
          im.BeginDisabled()
        end
        if im.InputInt("Make New Offer", myOfferValuePtr, nil, nil, im.InputTextFlags_EnterReturnsTrue) then
          makeOffer(myOfferValuePtr[0])
        end
        if disabled then
          im.EndDisabled()
        end

        if patience > 0.66 then im.PushStyleColor2(im.Col_Text, im.ImVec4(0.2, 1, 0.2, 1))
        elseif patience > 0.33 then im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 0.2, 1))
        else im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.2, 0.2, 1)) end

        im.Text("Patience: " .. patience)
        im.PopStyleColor()
        im.Text("Status: " .. negotiationStatus)

        if im.Button("Take their offer") then
          negotiationActive = false
        end
        if im.Button("Cancel negotiation") then
          negotiationActive = false
        end
      end
    im.End()
  end
  timeSinceUpdate = timeSinceUpdate + dtSim
  if timeSinceUpdate < 10 then return end
  timeSinceUpdate = 0

  -- Keep inventory part conditions current for driven listings so repair / value-loss
  -- gates in getListings match what the player just did to the car.
  for _, listing in ipairs(listedVehicles) do
    if not listing.rtBiz then
      syncSpawnedListingPartConditions(listing.id)
    end
  end

  generateNewOffers()
end

local function onVehicleRemoved(inventoryId)
  removeVehicleListing(inventoryId)
end

-- Mean part integrity, 0-100. Backs the condition bar on the vehicle info page; only
-- the player's own vehicles carry part conditions, marketplace stock does not.
local function getListingConditionPercent(veh)
  if type(veh.partConditions) ~= "table" then return nil end
  local total, count = 0, 0
  for _, partCondition in pairs(veh.partConditions) do
    local integrity = type(partCondition) == "table" and tonumber(partCondition.integrityValue) or nil
    if integrity then
      total = total + math.max(0, math.min(1, integrity))
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return math.floor((total / count) * 100 + 0.5)
end

-- Specs the phone marketplace shows on a listing row and on the vehicle info page.
-- Read straight off the inventory record so listings stay in sync with wear and repairs.
local function buildListingVehicleData(inventoryId)
  local veh = career_modules_inventory.getVehicles()[inventoryId]
  if not veh then return nil end

  local certifications = veh.certifications
  local power = certifications and tonumber(certifications.power) or nil
  local weight = certifications and tonumber(certifications.weight) or nil
  local torque = certifications and tonumber(certifications.torque) or nil

  return {
    year = veh.year,
    mileage = career_modules_valueCalculator.getVehicleMileageById(inventoryId),
    power = power and math.floor(power + 0.5) or nil,
    torque = torque and math.floor(torque + 0.5) or nil,
    weight = weight and math.floor(weight + 0.5) or nil,
    powerPerTonne = (power and weight and weight > 0) and math.floor((power / weight) * 1000 + 0.5) or nil,
    condition = getListingConditionPercent(veh),
    FRETimes = deepcopy(veh.FRETimes or {}),
    needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId),
  }
end

getListings = function()
  for _, listing in ipairs(listedVehicles) do
    refreshLiveListingValues(listing)
  end
  local timeNow = os.time()
  local listingsCopy = deepcopy(listedVehicles)
  for i, listing in ipairs(listingsCopy) do
    listing.niceName = core_locales.translateWithOrWithoutContext(listing.niceName)
    if not listing.rtBiz then
      listing.vehicleData = buildListingVehicleData(listing.id)
    end
    if listing.rtBiz then
      listing.marketValue = listing.marketValue or listing.value
    else
      local currentValue = career_modules_valueCalculator.getInventoryVehicleSellValue(listing.id)
      local originalMarketValue = listing.marketValueAtListing or listing.marketValue
      local origNum = tonumber(originalMarketValue) or 0
      if currentValue and origNum > 0 and currentValue < origNum * VALUE_LOSS_LIMIT then
        listing.disabled = true
        listing.disableReason = core_locales.contextTranslate("ui.career.vehicleMarketplace.disableReasonValueDrop", {
          percent = math.floor(VALUE_LOSS_LIMIT * 100),
        })
      end
      -- Only block accept when damage happened after listing. Cars listed already damaged
      -- stay sellable (value/offers are already reduced by repair cost in the sell value).
      local damagedAfterListing = listingDamagedAfterListing(listing, listing.id)
      listing.damagedAfterListing = damagedAfterListing
      if damagedAfterListing then
        listing.disabled = true
        listing.disableReason = listing.disableReason
          or "This vehicle was damaged after listing. Repair it before accepting offers."
      end
      listing.marketValue = currentValue or listing.marketValue
      if not listing.isManualValue and currentValue then
        listing.value = currentValue
      end
    end

    for _, offer in ipairs(listing.offers) do
      if offer.expiredViewCounter then
        offer.disabled = true
        offer.disableReason = _tr("ui.career.vehicleMarketplace.disableReasonOfferExpired")
      end
      -- countdown for the offers inbox; the UI ticks these down locally between refreshes
      local ttl = tonumber(offer.ttl) or OFFER_TTL
      offer.ttlTotal = math.floor(ttl)
      offer.secondsLeft = math.max(0, math.floor((tonumber(offer.timestamp) or timeNow) + ttl - timeNow))
      -- archetype quotes are locale keys; the private-seller pool is already plain text
      if offer.quote then
        offer.quote = _tr(offer.quote)
      end
    end

    if #listing.offers > 1 then
      -- reverse offers order so newest is at the top
      local reversed = {}
      for offerIndex = #listing.offers, 1, -1 do
        table.insert(reversed, listing.offers[offerIndex])
      end

      -- move disabled offers to the end
      local reordered = {}
      for _, offer in ipairs(reversed) do
        if not offer.disabled then
          table.insert(reordered, offer)
        end
      end
      for _, offer in ipairs(reversed) do
        if offer.disabled then
          table.insert(reordered, offer)
        end
      end
      listing.offers = reordered
    end
  end
  return listingsCopy
end

local function updateListings()
  if offerMenuOpen then
    local expiredOffersCount = 0
    for i, listing in ipairs(listedVehicles) do
      for offerIndex = #listing.offers, 1, -1 do
        local offer = listing.offers[offerIndex]
        if offer.expiredViewCounter then
          expiredOffersCount = expiredOffersCount + 1
          offer.expiredViewCounter = offer.expiredViewCounter + 1
          if offer.expiredViewCounter > 1 or expiredOffersCount > MAXIMUM_EXPIRED_OFFERS then
            table.remove(listing.offers, offerIndex)
          end
        end
      end
    end
  else
    local offerCountDiff = generateNewOffers()
    if offerCountDiff < 0 then
      for i = 1, math.abs(offerCountDiff) do
        local offer = generateOffer()
        offer.timestamp = offer.timestamp + math.random(1, OFFER_TTL)
      end
    end
  end
end

local function menuOpened(open)
  local newOfferMenuOpen = open or negotiationActive
  if newOfferMenuOpen == offerMenuOpen then return end
  offerMenuOpen = newOfferMenuOpen
  if offerMenuOpen then
    resetOfferBannerDigest()
  end
  updateListings()
end

local function openMenu(computerId)
  career_modules_vehicleShopping.openShop(nil, computerId, "marketplace")
end

local function onSaveCurrentProfile(currentSavePath, vehiclesThumbnailUpdate)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/marketplace.json", {
    listedVehicles = listedVehicles
  }, true)
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return end

  local data = jsonReadFile(savePath .. "/career/marketplace.json")
  if data then
    listedVehicles = data.listedVehicles
    local timeNow = os.time()
    for _, listing in ipairs(listedVehicles) do
      if listing.rtBiz then
        listing.marketValueAtListing = listing.marketValueAtListing or listing.marketValue or listing.value or 1
      else
        listing.marketValueAtListing = listing.marketValueAtListing or listing.marketValue or career_modules_valueCalculator.getInventoryVehicleSellValue(listing.id) or 1
      end
      listing.isManualValue = listing.isManualValue == nil and listing.value ~= (listing.marketValueAtListing or listing.marketValue) or listing.isManualValue
      listing.marketValue = listing.marketValueAtListing
      if not listing.bestOfferValue then
        local best = 0
        for _, offer in ipairs(listing.offers or {}) do
          local value = tonumber(offer.value) or 0
          if value > best then
            best = value
          end
        end
        if best > 0 then
          listing.bestOfferValue = best
        end
      end
      if not listing.timeOfNextOffer then
        scheduleNextOffer(listing, timeNow)
      end
    end
  end
end

M.firstNames = {
  "Aaliyah", "Aaron", "Abdullah", "Abigail", "Adam", "Aditya", "Adrian", "Adriana", "Adrien", "Agustin", "Ahmed", "Aisha", "Akari", "Akira", "Alan", "Albert", "Alberto", "Alejandra", "Alejandro", "Alessandro", "Alessia", "Alexander", "Alexandre", "Alexei", "Alexis", "Alfonso", "Alfredo", "Ali", "Alice", "Alicia", "Amanda", "Amandine", "Amber", "Amelia", "Amelie", "Amina", "Amir", "Amit", "Amparo", "Amy", "Ana", "Ananya", "Anastasia", "Andre", "Andrea", "Andreas", "Andrei", "Andres", "Andrew", "Angel", "Angela", "Anh", "Anjali", "Ann", "Anna", "Anselmo", "Anthony", "Antoine", "Anton", "Antonia", "Antonio", "Aoi", "Arjun", "Armando", "Artem", "Arthur", "Arturo", "Ascension", "Ashley", "Audrey", "Aurelie", "Aurora", "Austin", "Baptiste", "Barbara", "Beatrice", "Beatriz", "Benjamin", "Bernardo", "Betty", "Beverly", "Bilal", "Billy", "Binh", "Blanca", "Bobby", "Brandon", "Brenda", "Brian", "Brianna", "Brittany", "Bruce", "Bryan", "Camila", "Camille", "Cao", "Carl", "Carlos", "Carmen", "Carol", "Carolina", "Caroline", "Carolyn", "Catalina", "Catherine", "Cecile", "Celestino", "Celine", "Cesar", "Charles", "Charlotte", "Chen", "Cheng", "Cheryl", "Chiara", "Christian", "Christina", "Christine", "Christopher", "Claire", "Claudia", "Clement", "Concepcion", "Consuelo", "Cristian", "Cristina", "Cynthia", "Dalia", "Daniel", "Daniela", "Danielle", "Daria", "Dario", "Darius", "Darnell", "David", "Davide", "DeAndre", "Deborah", "Debra", "Deepika", "Deng", "Denis", "Denise", "Dennis", "Destiny", "Devonte", "Diana", "Diane", "Diego", "Dina", "Divya", "Dmitri", "Dolores", "Donald", "Donna", "Dorothy", "Douglas", "Duc", "Dylan", "Ebony", "Edoardo", "Eduardo", "Edward", "Ekaterina", "Elena", "Elisa", "Elisabeth", "Elise", "Eliseo", "Elizabeth", "Elodie", "Emilie", "Emilio", "Emily", "Emma", "Encarnacion", "Enrique", "Eric", "Erick", "Ernesto", "Esperanza", "Esteban", "Esther", "Ethan", "Eugene", "Eugenio", "Eun", "Eusebio", "Evelyn", "Fabian", "Fabien", "Faisal", "Fang", "Fatima", "Federico", "Felipe", "Felix", "Feng", "Fernanda", "Fernando", "Florian", "Frances", "Francesca", "Francesco", "Francisca", "Francisco", "Francois", "Frank", "Gabriel", "Gabriela", "Gabriele", "Gao", "Gary", "George", "Gerald", "Gerardo", "Ginevra", "Giorgia", "Giovanni", "Giulia", "Gloria", "Gonzalo", "Grace", "Graciela", "Gregory", "Greta", "Guadalupe", "Guillaume", "Guo", "Gustavo", "Hafsa", "Hai", "Hala", "Hamza", "Han", "Hana", "Hanan", "Hannah", "Harold", "Harry", "Haruka", "Hassan", "He", "Heather", "Hector", "Helen", "Helene", "Henri", "Henry", "Hiroshi", "Hoa", "Hu", "Huang", "Hugo", "Hui", "Hung", "Huong", "Hussein", "Hye", "Ibrahim", "Ignacio", "Igor", "Ines", "Irina", "Irma", "Isabel", "Isabelle", "Isha", "Isidro", "Ismael", "Ivan", "Jack", "Jacob", "Jacqueline", "Jalen", "Jamal", "James", "Jamil", "Jan", "Jane", "Janet", "Janice", "Jasmine", "Jason", "Javier", "Jean", "Jeffrey", "Jennifer", "Jeremy", "Jerry", "Jesse", "Jessica", "Ji", "Jimena", "Jin", "Jing", "Joan", "Joaquin", "Joe", "Johannes", "John", "Johnny", "Jonas", "Jonathan", "Jordan", "Jorge", "Jose", "Joseph", "Joshua", "Joyce", "Juan", "Juana", "Judith", "Judy", "Julia", "Julie", "Julien", "Juliette", "Julio", "Jun", "Justin", "Kai", "Karan", "Kareem", "Karen", "Karim", "Katharina", "Katherine", "Kathleen", "Kathryn", "Kathy", "Kavita", "Keisha", "Keith", "Kelly", "Kendrick", "Kenji", "Kenneth", "Kevin", "Khadija", "Khaled", "Khalid", "Kimberly", "Kiran", "Kristina", "Kyle", "Kyung", "Lan", "Larry", "Latoya", "Laura", "Lawrence", "Layla", "Lea", "Leandro", "Leila", "Leonardo", "Leticia", "Li", "Liliana", "Lin", "Lina", "Linda", "Ling", "Linh", "Lisa", "Liu", "Logan", "Lorenzo", "Lori", "Louis", "Luca", "Lucas", "Lucia", "Luis", "Lukas", "Luo", "Ma", "Madison", "Mahmoud", "Mai", "Malik", "Manoj", "Manon", "Manuel", "Manuela", "Marcelo", "Marco", "Marcus", "Margaret", "Margarita", "Maria", "Mariam", "Mariana", "Marie", "Marilyn", "Marina", "Marine", "Mario", "Marion", "Marisol", "Mark", "Markus", "Marquis", "Martha", "Martin", "Martina", "Mary", "Maryam", "Matteo", "Matthew", "Matthias", "Matthieu", "Maxim", "Maxime", "Maximilian", "Maximo", "Maya", "Meera", "Megan", "Mei", "Melanie", "Melissa", "Mercedes", "Mi", "Michael", "Michelle", "Miguel", "Mikhail", "Milagros", "Mildred", "Min", "Ming", "Mohammed", "Moises", "Mona", "Monica", "Monique", "Mustafa", "Na", "Nadia", "Nadine", "Nam", "Nancy", "Nasir", "Nasser", "Natalia", "Nathalie", "Nathan", "Natividad", "Neha", "Nestor", "Nga", "Nia", "Nicholas", "Nicolas", "Nicole", "Nikhil", "Nikolai", "Nina", "Nisha", "Noah", "Noha", "Noor", "Norma", "Nour", "Octavio", "Olga", "Olivier", "Omar", "Oscar", "Pablo", "Pamela", "Paola", "Patricia", "Patrick", "Paul", "Pauline", "Pavel", "Pedro", "Peter", "Petra", "Philip", "Philipp", "Philippe", "Phuong", "Piedad", "Pierre", "Pietro", "Pilar", "Polina", "Pooja", "Pradeep", "Presentacion", "Priya", "Purificacion", "Quang", "Rachel", "Rafael", "Rahul", "Raj", "Ralph", "Rami", "Ramon", "Rana", "Randy", "Rania", "Raquel", "Rashid", "Raul", "Ravi", "Raymond", "Rebecca", "Reem", "Regina", "Remedios", "Renato", "Rene", "Ricardo", "Riccardo", "Richard", "Rima", "Rin", "Riya", "Robert", "Roberto", "Rocio", "Rodolfo", "Rodrigo", "Rogelio", "Roger", "Rohan", "Romain", "Roman", "Ronald", "Rosa", "Rosario", "Rose", "Roy", "Ruben", "Russell", "Ryan", "Ryo", "Sabine", "Safiya", "Sakura", "Salma", "Salvador", "Salvatore", "Samantha", "Sami", "Samira", "Samuel", "Sandra", "Sang", "Sara", "Sarah", "Satoshi", "Saul", "Scott", "Sean", "Sebastian", "Sebastien", "Sergei", "Sergio", "Seung", "Shanice", "Sharon", "Shirley", "Shreya", "Siddharth", "Silvia", "Simon", "Simone", "Sneha", "Sofia", "Soledad", "Song", "Soo", "Sophie", "Stefan", "Stephanie", "Stephen", "Steven", "Sun", "Suresh", "Susan", "Susana", "Susanne", "Svetlana", "Swati", "Takeshi", "Tamer", "Tang", "Tanvi", "Tarek", "Tariq", "Tatiana", "Teodoro", "Teresa", "Terry", "Thao", "Theresa", "Thomas", "Tiffany", "Tim", "Timothy", "Tobias", "Tomas", "Tommaso", "Trevon", "Tuan", "Tyler", "Tyrone", "Valentin", "Valentina", "Valeria", "Valerio", "Vanessa", "Varun", "Veronica", "Victor", "Victoria", "Vikram", "Viktor", "Vincent", "Vincenzo", "Virginia", "Virginie", "Visitacion", "Vladimir", "Waleed", "Walter", "Wayne", "Wei", "William", "Willie", "Woo", "Wu", "Xia", "Xie", "Ximena", "Xu", "Yan", "Yang", "Yasmin", "Yolanda", "Young", "Youssef", "Yuan", "Yui", "Yuki", "Yulia", "Yusuf", "Yusuke", "Zachary", "Zain", "Zainab", "Zhang", "Zhao", "Zheng", "Zhou", "Zhu", "Zoe"
}
M.firstNameCount = #M.firstNames

M.initialProbabilities= {
  A = 0.038,
  B = 0.085,
  C = 0.077,
  D = 0.045,
  E = 0.019,
  F = 0.034,
  G = 0.056,
  H = 0.071,
  I = 0.004,
  J = 0.030,
  K = 0.033,
  L = 0.049,
  M = 0.096,
  N = 0.019,
  O = 0.015,
  P = 0.050,
  Q = 0.002,
  R = 0.059,
  S = 0.094,
  T = 0.035,
  U = 0.002,
  V = 0.018,
  W = 0.055,
  X = 0.0004,
  Y = 0.006,
  Z = 0.006,
}
M.initials = {}
for initial, probability in pairs(M.initialProbabilities) do
  for i = 1, math.ceil(probability * 100) do
    table.insert(M.initials, initial)
  end
end
M.initialCount = #M.initials


M.privateSellerQuotes = {
  "Just want it gone, moving next week.",
  "Hate to see her go, but need the space.",
  "Been in the family for years, well maintained.",
  "Price is firm, I know what I have.",
  "Make me an offer, need cash ASAP.",
  "No lowballers, I know what it's worth.",
  "Garage kept, all service records available.",
  "Drove it myself for 5 years, runs great.",
  "Life changes, gotta sell unfortunately.",
  "Open to reasonable offers.",
  "Priced to sell this weekend.",
  "Take care of it and it'll take care of you.",
  "Never had any issues with it.",
  "Only selling because I upgraded.",
  "Don't waste my time with ridiculous offers.",
  "First reasonable offer takes it.",
  "Selling for a friend, flexible on price.",
  "Mechanically sound, cosmetically rough.",
  "It's been reliable for me.",
  "New job means I don't need it anymore.",
  "Adult owned, never abused.",
  "Clean title in hand, ready to transfer.",
  "Runs and drives, needs some TLC.",
  "Everything works as it should.",
  "Minor cosmetic issues, drives perfect.",
  "Recent oil change and new tires.",
  "Hate to part with it, but downsizing.",
  "Priced below book value for quick sale.",
  "Zero mechanical problems, drives smooth.",
  "Cold AC, heat works great too.",
  "Always serviced on time.",
  "Second owner, bought from family.",
  "Won't find a better deal than this.",
  "Serious inquiries only please.",
  "Text is best, I work nights.",
  "Can meet at DMV to transfer title.",
  "No joy rides, cash talks.",
  "Perfect winter car, starts every time.",
  "Great gas mileage, very economical.",
  "Retiring and don't need two cars.",
  "Baby on the way, need something bigger.",
  "Moving out of state next month.",
  "Estate sale, must sell quickly.",
  "Lost my license, don't need it anymore.",
  "Bought a truck, this has to go.",
  "Wife's car, she wants something newer.",
  "College kid car, heading off to school.",
  "Transmission rebuilt last year.",
  "Just passed inspection last month.",
  "Great starter car for a teenager."
}

M.dealershipBuyerQuotes = {
  "We're always looking for quality inventory.",
  "Let me see what I can offer you for this.",
  "I'll need to get it appraised, but we're interested.",
  "We can make you an offer today.",
  "What are you looking to get out of it?",
  "We buy cars in any condition.",
  "I can take it off your hands.",
  "We're prepared to make a fair offer.",
  "Let me run the numbers real quick.",
  "We need inventory, I can work with you.",
  "I'll have to inspect it first, but we're interested.",
  "We can process this today if the price is right.",
  "What's your bottom line on it?",
  "We're in the market for one of these.",
  "I can make you an offer, but it needs to be realistic.",
  "We'll need to account for reconditioning costs.",
  "Let's talk numbers.",
  "We buy dozens of cars every month.",
  "I can give you a quote, but our margins are tight.",
  "We're definitely interested in adding this to our lot.",
  "What were you hoping to get for it?",
  "We can make this quick and easy for you.",
  "I'll need to factor in wholesale value.",
  "We're always buying - let's make a deal.",
  "I can write you a check today."
}

M.onUpdate = onUpdate
M.onVehicleRemoved = onVehicleRemoved
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded

M.getListings = getListings
M.menuOpened = menuOpened
M.acceptOffer = acceptOffer
M.acceptOfferById = acceptOfferById
M.declineOfferById = declineOfferById
M.declineOffer = deleteOffer
M.listVehicles = listVehicles
M.findVehicleListing = findVehicleListing
M.openMenu = openMenu
M.removeVehicleListing = removeVehicleListing
M.updateListingValue = updateListingValue
M.addRtListing = addRtListing
M.generateOffer = generateOffer

M.generatePersonality = generatePersonality
M.startNegotiateBuyingOffer = startNegotiateBuyingOffer
M.startNegotiateBuyingOfferById = startNegotiateBuyingOfferById
M.startNegotiateSellingOffer = startNegotiateSellingOffer
M.startCarMeetBuyingOffer = startCarMeetBuyingOffer
M.getNegotiationState = getNegotiationState
M.makeNegotiationOffer = makeNegotiationOffer
M.takeTheirOffer = takeTheirOffer
M.cancelNegotiation = cancelNegotiation
M.dismissNegotiation = dismissNegotiation
M.setPhoneMarketplaceUiOpen = setPhoneMarketplaceUiOpen
M.finishPhonePurchase = finishPhonePurchase
M.routeToListing = routeToListing
M.goToListing = goToListing

local function notifyOnPhoneAppInstalled()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return
  end
  local pendingCount = countPendingOffers()
  if pendingCount <= 0 then
    return
  end
  local waitingLabel = pendingCount == 1 and "You have 1 offer waiting" or ("You have " .. pendingCount .. " offers waiting")
  fireMarketplacePhoneNotification(
    "marketplace.newOffer",
    "Marketplace",
    waitingLabel,
    nil,
    "invite",
    {
      ttl = DIGEST_OFFER_TTL,
      forceTtl = true,
      replaceKey = DIGEST_REPLACE_KEY,
    }
  )
end

M.notifyOnPhoneAppInstalled = notifyOnPhoneAppInstalled

return M
