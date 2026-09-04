local M = {}
M.dependencies = {
    'gameplay_sites_sitesManager',
    'freeroam_facilities',
    'gameplay_walk',
    'gameplay_phone',
    'gameplay_delivery_logisticsXPConfig'
}

M.config = {
    -- Driving smoothness
    roughEventThreshold = 1.2, 
    tipTiers = {
        { maxEvents = 0, percent = 0.55 },
        { maxEvents = 5, percent = 0.40 },
        { maxEvents = 10, percent = 0.22 },
        { maxEvents = 20, percent = 0.08 }
    },

    averageSpeedMPS = 16,

    bonusPerSecondEarly = 100,
    penaltyPerSecondLate = 0,
    onTimeBonusPercent = 0.13,
    
    baseFarePerKm = 105,
    zeroTipChance = 0.03,
    hugeTipChance = 0.08,
    stopVelocityThreshold = 0.5,
    pickupDropoffDuration = 3.0,
    pickupDropoffTimeBuffer = 6, -- Seconds added to expected time for pickup/dropoff actions
    
    streakMultiplierPerLevel = 0.03,
    streakMultiplierMax = 1.0,

    maxRatingBonus = 0.9,
    logisticsMultCap = 0.75,
    
    -- Job Interval (seconds)
    intervalMinRating = {min = 40, max = 60}, 
    intervalMaxRating = {min = 1, max = 3},   
    
    ratingDampeningCount = 4,

    roughEventRatingPenalty = 0.25,
    lateDeliveryRatingPenalty = 0.45,
    onTimeRatingBonus = 0.35,
    ratingPullTowardFive = 0.18,

    -- Radius Scaling
    baseDeliveryRadius = 1000, -- meters at 0 stars
    radiusStep = 100, -- meters increase per ratingStep
    radiusStepRatingInterval = 0.3, -- rating interval for radius increase

    -- Order generation: nearest restaurants + expanding dropoff search
    minDeliveryAirDistance = 600,
    localRestaurantPoolSize = 3,
    recentRestaurantCooldown = 2,
    longHaulChanceMin = 0.18,
    longHaulChancePerRating = 0.03, -- +3% per star, ~0.33 at 5*
    dropoffExpandStep = 500,
    localDropoffMaxCap = 3500,
    longHaulDropoffStartMin = 2000,
    longHaulDropoffMaxCap = 8000,
    dropoffRoadCheckAttempts = 15,
    dropoffRoadDistanceFactor = 2.0,
    restaurantPickAttempts = 6,
}

local config = M.config

local promotionTiers = {
    { flag = "beamEatsDriverBronze", label = "Bronze Courier", payBonus = 0.08, xpMultiplier = 1.10, minLogisticsLevel = 5 },
    { flag = "beamEatsDriverSilver", label = "Silver Courier", payBonus = 0.16, xpMultiplier = 1.20, minLogisticsLevel = 10 },
    { flag = "beamEatsDriverGold", label = "Gold Courier", payBonus = 0.24, xpMultiplier = 1.30, minLogisticsLevel = 15 },
    { flag = "beamEatsDriverPlatinum", label = "Platinum Courier", payBonus = 0.32, xpMultiplier = 1.40, minLogisticsLevel = 20 },
    { flag = "beamEatsDriverElite", label = "Elite Courier", payBonus = 0.40, xpMultiplier = 1.50, minLogisticsLevel = 25 },
}

-- ================================
-- MODULE DEPENDENCIES
-- ================================
local core_groundMarkers = require('core/groundMarkers')

-- ================================
-- STATE VARIABLES
-- ================================
local dataToSend = {}
local cumulativeReward = 0
local orderStreak = 0
local currentOrder = nil
local state = "start"
local timer = 0
local dwellTimer = 0
local dwellDuration = config.pickupDropoffDuration 

local updateTimer = 1
local uiUpdateTimer = 0
local jobOfferTimer = 0

local jobOfferInterval = 60

local vehicleMultiplier = 0.1

local restaurants = {}
local allDeliverySpots = nil
local lastRatingDelta = nil
local recentRestaurantIds = {}

local ratingSaveFile = "beamEatsRating.json"
local playerRating = 0.0 
local ratingCount = 0
local ratingSum = 0

M.deliveryData = {}

local function getLogisticsLevel()
    if career_branches and career_branches.getBranchLevel then
        local level = career_branches.getBranchLevel("logistics-delivery")
        if type(level) == "number" then
            return level
        end
    end
    return 0
end

local function getLogisticsMoneyBonusMultiplier()
    local level = getLogisticsLevel()
    local effectiveLevel = math.max(1, math.min(50, math.floor(tonumber(level) or 1)))
    local rawBonus = 0
    for unlockedLevel = 2, math.min(49, effectiveLevel) do
        if ((unlockedLevel - 2) % 2) + 1 == 2 then rawBonus = rawBonus + 0.08 end
    end
    if effectiveLevel >= 50 then rawBonus = rawBonus + 0.08 end
    return 1.0 + rawBonus, rawBonus
end

local function calculateRatingPayMultiplier(rating)
    local maxBonus = config.maxRatingBonus or 0.9
    local normalized = math.min(1.0, math.max(0.0, (rating or 0) / 5.0))
    return 1.0 + (normalized * normalized) * maxBonus
end

local function formatPlayerRatingDisplay(forCompletion)
    if forCompletion and lastRatingDelta then
        if math.abs(lastRatingDelta) < 0.005 then
            return string.format("%.2f / 5.0 (0.00)", playerRating)
        end
        return string.format("%.2f / 5.0 (%+.2f)", playerRating, lastRatingDelta)
    end
    return string.format("%.2f / 5.0", playerRating)
end

local function getPromotionState()
    return "Courier", 0, 1.0
end

local function getBeamEatsXpRules()
    if gameplay_delivery_logisticsXPConfig and gameplay_delivery_logisticsXPConfig.getBeamEatsRules then
        return gameplay_delivery_logisticsXPConfig.getBeamEatsRules()
    end
    return {
        baseXP = 24,
        distanceDivisor = 400,
        xpRounding = "round",
        streakTiers = {
            { maxStreak = 5, xp = 4 },
            { maxStreak = 15, xp = 6 },
            { maxStreak = 20, xp = 10 },
            { maxStreak = 30, xp = 12 },
            { maxStreak = 40, xp = 16 },
            { maxStreak = 45, xp = 20 },
            { maxStreak = 999999, xp = 30 }
        }
    }
end

local function getStreakXpBonus(streak)
    local rules = getBeamEatsXpRules()
    local tiers = rules.streakTiers or {}
    for _, tier in ipairs(tiers) do
        if streak <= (tier.maxStreak or 0) then
            return tier.xp or 0
        end
    end
    return 0
end

local function calculateLogisticsXp(distanceMeters, streak)
    local rules = getBeamEatsXpRules()
    local baseXP = tonumber(rules.baseXP) or 24
    local distanceDivisor = tonumber(rules.distanceDivisor) or 400
    local xpRounding = rules.xpRounding or "round"
    local roundFn = round
    if gameplay_delivery_logisticsXPConfig and gameplay_delivery_logisticsXPConfig.applyRounding then
        roundFn = function(value)
            return gameplay_delivery_logisticsXPConfig.applyRounding(value, xpRounding)
        end
    end

    local distanceXp = 0
    if distanceMeters and distanceDivisor > 0 then
        distanceXp = roundFn(distanceMeters / distanceDivisor)
    end

    local _, _, xpMultiplier = getPromotionState()
    local rawXp = (baseXP + distanceXp + getStreakXpBonus(streak)) * xpMultiplier
    return math.max(0, roundFn(rawXp))
end

local function calculateJobOfferInterval()
    -- Calculate interval based on player rating
    local t = math.min(1.0, math.max(0.0, playerRating / 5.0))
    local minInterval = config.intervalMinRating.min + (config.intervalMaxRating.min - config.intervalMinRating.min) * t
    local maxInterval = config.intervalMinRating.max + (config.intervalMaxRating.max - config.intervalMinRating.max) * t
    
    local floorMin = math.floor(minInterval)
    local floorMax = math.floor(maxInterval)
    
    -- Ensure floorMax >= floorMin to avoid math.random error
    if floorMax < floorMin then floorMax = floorMin end
    
    return math.random(floorMin, floorMax)
end

local function savePlayerRating(currentSavePath)
    if not career_career or not career_career.isActive() then return end
    if not currentSavePath then
        local _, path = career_saveSystem.getCurrentProfile()
        currentSavePath = path
        if not currentSavePath then return end
    end

    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    local data = {
        sum = ratingSum,
        count = ratingCount,
        average = playerRating
    }
    career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. ratingSaveFile, data, true)
end

local function loadPlayerRating()
    if not career_career or not career_career.isActive() then return end
    local _, path = career_saveSystem.getCurrentProfile()
    if not path then return end
    local filePath = path .. "/career/rls_career/" .. ratingSaveFile
    local data = jsonReadFile(filePath) or {}
    ratingSum = tonumber(data.sum or 0) or 0
    ratingCount = tonumber(data.count or 0) or 0
    
    local virtualStartCount = config.ratingDampeningCount or 4
    local virtualStartRating = 0.0
    
    local effectiveSum = ratingSum + (virtualStartCount * virtualStartRating)
    local effectiveCount = ratingCount + virtualStartCount
    
    playerRating = math.max(0.0, math.min(5.0, effectiveSum / effectiveCount))
end

local function isBeamEatsDisabled()
    local disabled = false
    local reason = ""

    if gameplay_walk and gameplay_walk.isWalking() then
        disabled = true
        reason = "BeamEats is not available while walking"
        return disabled, reason
    end

    if career_economyAdjuster then
        local beamEatsMultiplier = career_economyAdjuster.getSectionMultiplier("beamEats") or 1.0
        if beamEatsMultiplier == 0 then
            disabled = true
            reason = "BeamEats multiplier is set to 0"
            return disabled, reason
        end
    end

    if not restaurants or #restaurants == 0 then
        disabled = true
        reason = "Not available"
        return disabled, reason
    end

    if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
        disabled = true
        reason = "Not available"
        return disabled, reason
    end

    return disabled, reason
end

-- ================================
-- HELPER FUNCTIONS
-- ================================
local function buildBeamEatsStateData()
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    local ratingStr = formatPlayerRatingDisplay(state == "completed")

    local previewStreak = orderStreak + 1
    local previewDistance = currentOrder and currentOrder.totalDistance or 0
    local streakXP = currentOrder and currentOrder.streakXP
    if streakXP == nil then
        streakXP = calculateLogisticsXp(previewDistance, previewStreak)
    end

    local promotionLabel, promotionPayBonus, promotionXpMultiplier = getPromotionState()
    local logisticsLevel = getLogisticsLevel()
    local _, logisticsPayBonus = getLogisticsMoneyBonusMultiplier()
    local promotionPayPercent = math.floor((promotionPayBonus or 0) * 100 + 0.5)
    local promotionXpPercent = math.floor(((promotionXpMultiplier or 1) - 1) * 100 + 0.5)
    local logisticsPayPercent = math.floor((logisticsPayBonus or 0) * 100 + 0.5)

    return {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        streakXP = streakXP,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason,
        playerRating = ratingStr,
        promotionLabel = promotionLabel,
        promotionPayPercent = promotionPayPercent,
        promotionXpPercent = promotionXpPercent,
        logisticsLevel = logisticsLevel,
        logisticsPayPercent = logisticsPayPercent
    }
end

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local requestBeamEatsState
local startDelivery

-- ================================
-- SENSOR DATA HANDLING
local function updateSensorData()
    if not currentOrder or state ~= "dropoff" then
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return
    end

    vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua('gameplay_beamEats.receiveSensorData('..gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2..')')
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
    local grav = 9.81 
    M.deliveryData.currentSensorData = {
        gx = gx / grav,
        gy = gy / grav,
        gz = gz / grav,
        gx2 = gx2 / grav,
        gy2 = gy2 / grav,
        gz2 = gz2 / grav,
        timestamp = os.time()
    }

    if not M.deliveryData.roughEvents then
        M.deliveryData.roughEvents = 0
    end
    if not M.deliveryData.isRoughEventActive then
        M.deliveryData.isRoughEventActive = false
    end

    local peak = math.max(math.abs(gx2 / grav), math.abs(gy2 / grav), math.abs(gz2 / grav))
    
    if M.deliveryData.isRoughEventActive then
        if peak < (config.roughEventThreshold * 0.8) then
            M.deliveryData.isRoughEventActive = false
        end
    else
        if peak > config.roughEventThreshold then
            M.deliveryData.roughEvents = M.deliveryData.roughEvents + 1
            M.deliveryData.isRoughEventActive = true
        end
    end
end

-- ================================
-- RESTAURANT AND LOCATION MANAGEMENT
local function findRestaurants()
    restaurants = {}
    local facilities = freeroam_facilities.getFacilitiesByType("deliveryProvider")

    if not facilities then
        return
    end

    local restaurantParkingSpotNames = {}

    for _, fac in ipairs(facilities) do
        -- Check if facility provides food delivery, regardless of ID
        local isRestaurant = false
        if fac.manualAccessPoints then
            for _, accessPoint in ipairs(fac.manualAccessPoints) do
                if accessPoint.logisticTypesProvided then
                    for _, logisticType in ipairs(accessPoint.logisticTypesProvided) do
                        if logisticType == "food" or logisticType == "takeout" then
                            isRestaurant = true
                            break
                        end
                    end
                end
                if isRestaurant then break end
            end
        end

        if isRestaurant then
            local pickupSpots = {}
            if fac.manualAccessPoints then
                for _, accessPoint in ipairs(fac.manualAccessPoints) do
                    if accessPoint.logisticTypesProvided then
                        for _, logisticType in ipairs(accessPoint.logisticTypesProvided) do
                            if logisticType == "food" or logisticType == "takeout" then
                                table.insert(restaurantParkingSpotNames, accessPoint.psName)

                                local sitesFile = fac.sitesFile
                                if sitesFile then
                                    local siteData = gameplay_sites_sitesManager.loadSites(sitesFile)
                                    if siteData and siteData.parkingSpots then
                                        -- Check if byName exists before accessing
                                        if siteData.parkingSpots.byName then
                                            local ps = siteData.parkingSpots.byName[accessPoint.psName]
                                            if ps and ps.pos then
                                                table.insert(pickupSpots, {
                                                    pos = ps.pos,
                                                    name = accessPoint.psName,
                                                    restaurantId = fac.id,
                                                    restaurantName = fac.name
                                                })
                                            end
                                        end
                                    end
                                end
                                break
                            end
                        end
                    end
                end
            end

            if #pickupSpots > 0 then
                table.insert(restaurants, {
                    id = fac.id,
                    name = fac.name,
                    pickupSpots = pickupSpots
                })
            end
        end
    end

    M.restaurantParkingSpotNames = restaurantParkingSpotNames
end

local function findAllDeliveryParkingSpots()
    local allSitesFiles = gameplay_sites_sitesManager.getCurrentLevelSitesFiles()
    if not allSitesFiles then
        local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('city')
        if sitePath then
            allSitesFiles = {sitePath}
        else
            return
        end
    end

    local allParkingSpots = {}
    local restaurantSpotNames = M.restaurantParkingSpotNames or {}
    local restaurantSpotsLookup = {}
    for _, spotName in ipairs(restaurantSpotNames) do
        restaurantSpotsLookup[spotName] = true
    end

    for _, sitesFilePath in ipairs(allSitesFiles) do
        if not string.find(sitesFilePath, "restaurants") then
            local siteData = gameplay_sites_sitesManager.loadSites(sitesFilePath, true, true)
            if siteData and siteData.parkingSpots and siteData.parkingSpots.objects then
                for _, spot in pairs(siteData.parkingSpots.objects) do
                    if spot.name and not restaurantSpotsLookup[spot.name] then
                        if spot.pos then
                            -- Fallback to filename if no zone found or if zone name is generic
                            -- We still calculate this as a backup, but getDeliveryLocationName checks spot.zones first
                            if not spot.zoneName then
                                local _, filename = string.match(sitesFilePath, "(.-)([^\\/]-%.?([^%.\\/]*))$")
                                if filename then
                                    local cleanName = string.gsub(filename, "%.sites%.json", "")
                                    cleanName = string.gsub(cleanName, "%.json", "")
                                    local lowerName = string.lower(cleanName)
                                    if lowerName ~= "city" and lowerName ~= "facilities" then
                                        spot.zoneName = cleanName:gsub("^%l", string.upper)
                                    end
                                end
                            end

                            table.insert(allParkingSpots, spot)
                        end
                    end
                end
            end
        end
    end

    allDeliverySpots = {
        objects = allParkingSpots
    }
end

-- ================================
-- DISABLED STATE CHECK
-- (Moved to top of file)
-- ================================


-- ================================
-- VALUE AND PAYMENT CALCULATIONS
local function generateValueMultiplier()
    if not career_career or not career_career.isActive() then
        return 1
    end
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
        return 0.1
    end
    if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
        return 0.1
    end
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehicle:getID())
    if not inventoryId then
        return 0
    end
    if not career_modules_valueCalculator or not career_modules_valueCalculator.getInventoryVehicleValue then
        return 0.1
    end
    vehicleMultiplier = (career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) / 30000) ^ 0.5
    vehicleMultiplier = math.max(vehicleMultiplier, 0.1)
    return vehicleMultiplier
end

local function calculateDrivingDistance(startPos, endPos)
    local startRoad, _, startDist = map.findClosestRoad(startPos)
    local endRoad, _, endDist = map.findClosestRoad(endPos)

    if not startRoad or not endRoad then
        return startPos:distance(endPos) * 2.0
    end

    local path = map.getPath(startRoad, endRoad)
    if not path or #path == 0 then
        return startPos:distance(endPos) * 2.0
    end

    local totalDistance = 0
    local prevNodePos = startPos
    local mapData = map.getMap()
    
    if not mapData or not mapData.nodes then
        return startPos:distance(endPos) * 2.0
    end

    local lastRoadNode = nil
    for i = 1, #path do
        local node = mapData.nodes[path[i]]
        if node then
            local nodePos = node.pos
            if prevNodePos then
                totalDistance = totalDistance + prevNodePos:distance(nodePos)
            end
            prevNodePos = nodePos
            lastRoadNode = nodePos
        end
    end

    -- Add distance from last path node to destination
    if lastRoadNode then
        totalDistance = totalDistance + lastRoadNode:distance(endPos)
    else
        totalDistance = totalDistance + prevNodePos:distance(endPos)
    end

    return totalDistance
end

local function computeDistancePay(totalDistance)
    local distancePay = config.baseFarePerKm * (totalDistance / 1000)
    local economyMultiplier = 1.0

    if career_economyAdjuster then
        economyMultiplier = career_economyAdjuster.getSectionMultiplier("beamEats") or 1.0
        distancePay = distancePay * economyMultiplier
    end

    return distancePay, economyMultiplier
end

local function computeOrderBaseFare(totalDistance)
    local distancePay, economyMultiplier = computeDistancePay(totalDistance)
    local logisticsMult = select(1, getLogisticsMoneyBonusMultiplier())
    local coreBase = distancePay * logisticsMult
    local ratingMult = calculateRatingPayMultiplier(playerRating)
    local _, promotionPayBonus = getPromotionState()
    local baseFare = coreBase * ratingMult * (1 + promotionPayBonus)
    return math.floor(baseFare + 0.5), economyMultiplier
end

local function applyOrderFareFields(order, totalDistance)
    local baseFare, economyMultiplier = computeOrderBaseFare(totalDistance)
    local _, logisticsPayBonus = getLogisticsMoneyBonusMultiplier()

    order.baseFare = baseFare
    order.totalDistance = totalDistance
    order.economyMultiplier = economyMultiplier or 1.0
    order.demandMultiplier = (career_modules_activityHeat and career_modules_activityHeat.getDemandFactor and career_modules_activityHeat.getDemandFactor("beamEats")) or 1.0
    order.baseFareDisplay = string.format("%.2f (%s)", baseFare, formatPlayerRatingDisplay(false))
    order.totalPaymentDisplay = string.format("%.2f", baseFare)
    order.totalDistanceDisplay = string.format("%.2f", totalDistance / 1000)
    order.logisticsPayPercent = math.floor((logisticsPayBonus or 0) * 100 + 0.5)

    return order
end

local function calculateTimeFactor()
    if not currentOrder or not currentOrder.startTime then
        return 0
    end

    local elapsedTime = timer - currentOrder.startTime
    local expectedTime = currentOrder.expectedTime or 300
    local speedFactor = (expectedTime - elapsedTime) / expectedTime

    return math.max(-1.0, math.min(1.0, speedFactor))
end

local function calculateSmoothDrivingTip(baseFare, roughEvents)
    local rand = math.random()

    if rand < config.zeroTipChance then
        return 0
    end

    if rand < (config.zeroTipChance + config.hugeTipChance) then
        return baseFare
    end

    -- Create a sorted local copy of tipTiers to avoid ordering issues
    local tiers = {}
    for _, t in ipairs(config.tipTiers) do table.insert(tiers, t) end
    table.sort(tiers, function(a, b) return a.maxEvents < b.maxEvents end)

    for _, tier in ipairs(tiers) do
        if roughEvents <= tier.maxEvents then
            return baseFare * tier.percent
        end
    end
    
    -- Fallback for > 20 events (very rough driving)
    -- Generous customers (50% chance) will still give a small tip (5%)
    if math.random() < 0.5 then
        return baseFare * 0.05
    end

    return 0
end

-- ================================
local function getDeliveryLocationName(spot)
    if not spot then return "Customer" end

    -- 1. Zone Name (Pre-calculated by game sites manager)
    if spot.zones then
        -- spot.zones is a list/table of zones this spot belongs to
        -- We just pick the first one's name, or look for a specific type if needed.
        -- Usually zones are named nicely like "Downtown", "Industrial", etc.
        for _, zone in pairs(spot.zones) do
            if zone.name then
                return zone.name
            end
        end
    end
    
    -- 2. Zone Name (Fallback: manually attached in findAllDeliveryParkingSpots if native lookup fails)
    if spot.zoneName then
        return spot.zoneName
    end
    
    return "Customer"
end

local function rememberRecentRestaurant(restaurantId)
    if not restaurantId then
        return
    end
    for i = #recentRestaurantIds, 1, -1 do
        if recentRestaurantIds[i] == restaurantId then
            table.remove(recentRestaurantIds, i)
        end
    end
    table.insert(recentRestaurantIds, 1, restaurantId)
    local keep = tonumber(config.recentRestaurantCooldown) or 2
    while #recentRestaurantIds > keep do
        table.remove(recentRestaurantIds)
    end
end

local function isRecentRestaurant(restaurantId)
    for _, id in ipairs(recentRestaurantIds) do
        if id == restaurantId then
            return true
        end
    end
    return false
end

local function getRestaurantAnchorPos(restaurant)
    if not restaurant or not restaurant.pickupSpots then
        return nil
    end
    for _, spot in ipairs(restaurant.pickupSpots) do
        if spot and spot.pos then
            return spot.pos
        end
    end
    return nil
end

local function restaurantHasAirDropoff(restaurant, minDistance, maxDistance)
    if not restaurant or not restaurant.pickupSpots or not allDeliverySpots or not allDeliverySpots.objects then
        return false
    end
    for _, pickup in ipairs(restaurant.pickupSpots) do
        if pickup and pickup.pos then
            for _, spot in pairs(allDeliverySpots.objects) do
                if spot and spot.pos then
                    local dist = pickup.pos:distance(spot.pos)
                    if dist >= minDistance and dist <= maxDistance then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function getBaseDropoffMaxDistance()
    return config.baseDeliveryRadius
        + (math.floor(playerRating / config.radiusStepRatingInterval) * config.radiusStep)
end

local function findValidDropoff(pickupPos, minDistance, startMaxDistance, absoluteMaxDistance)
    if not pickupPos or not allDeliverySpots or not allDeliverySpots.objects then
        return nil, nil
    end

    local expandStep = tonumber(config.dropoffExpandStep) or 500
    local maxAttempts = tonumber(config.dropoffRoadCheckAttempts) or 15
    local roadDistanceFactor = tonumber(config.dropoffRoadDistanceFactor) or 2.0
    local maxDistance = math.max(minDistance, startMaxDistance or minDistance)
    local absoluteMax = math.max(maxDistance, absoluteMaxDistance or maxDistance)

    while maxDistance <= absoluteMax + 0.01 do
        local potentialSpots = {}
        for _, spot in pairs(allDeliverySpots.objects) do
            if spot and spot.pos then
                local airDist = pickupPos:distance(spot.pos)
                if airDist >= minDistance and airDist <= maxDistance then
                    table.insert(potentialSpots, spot)
                end
            end
        end

        local roadAllowance = maxDistance * roadDistanceFactor
        local attempts = 0
        while #potentialSpots > 0 and attempts < maxAttempts do
            attempts = attempts + 1
            local index = math.random(#potentialSpots)
            local spot = potentialSpots[index]
            local roadDist = calculateDrivingDistance(pickupPos, spot.pos)
            if roadDist <= roadAllowance then
                return spot, roadDist
            end
            table.remove(potentialSpots, index)
        end

        if maxDistance >= absoluteMax then
            break
        end
        maxDistance = math.min(absoluteMax, maxDistance + expandStep)
    end

    return nil, nil
end

local function weightedPickRestaurant(pool)
    if not pool or #pool == 0 then
        return nil
    end
    local totalWeight = 0
    for _, entry in ipairs(pool) do
        totalWeight = totalWeight + (entry.weight or 1)
    end
    if totalWeight <= 0 then
        return pool[math.random(#pool)].restaurant
    end
    local roll = math.random() * totalWeight
    local cumulative = 0
    for _, entry in ipairs(pool) do
        cumulative = cumulative + (entry.weight or 1)
        if roll <= cumulative then
            return entry.restaurant
        end
    end
    return pool[#pool].restaurant
end

local function buildRestaurantPools(vehiclePos, minDistance, viabilityMaxDistance)
    local viable = {}
    for _, restaurant in ipairs(restaurants) do
        local anchor = getRestaurantAnchorPos(restaurant)
        if anchor and restaurantHasAirDropoff(restaurant, minDistance, viabilityMaxDistance) then
            local dist = vehiclePos:distance(anchor)
            table.insert(viable, {
                restaurant = restaurant,
                dist = dist,
                weight = 1 / (dist + 50),
            })
        end
    end

    table.sort(viable, function(a, b)
        return a.dist < b.dist
    end)

    local localPoolPreferred = {}
    local localPoolFallback = {}
    local poolSize = tonumber(config.localRestaurantPoolSize) or 3
    for i = 1, math.min(poolSize, #viable) do
        local entry = viable[i]
        if isRecentRestaurant(entry.restaurant.id) then
            table.insert(localPoolFallback, entry)
        else
            table.insert(localPoolPreferred, entry)
        end
    end

    -- If the nearest few are all on cooldown, still allow them.
    local localPool = (#localPoolPreferred > 0) and localPoolPreferred or localPoolFallback

    return localPool, viable
end

local function generateOrder()
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    if beamEatsDisabled then
        return nil
    end

    if #restaurants == 0 then
        return nil
    end

    if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
        return nil
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return nil
    end

    local vehiclePos = vehicle:getPosition()
    local minDistance = tonumber(config.minDeliveryAirDistance) or 600
    local baseMaxDistance = getBaseDropoffMaxDistance()
    local localCap = math.max(baseMaxDistance, tonumber(config.localDropoffMaxCap) or 3500)
    local longHaulCap = math.max(localCap, tonumber(config.longHaulDropoffMaxCap) or 8000)
    local longHaulStartMin = tonumber(config.longHaulDropoffStartMin) or 2000
    local longHaulChance = (tonumber(config.longHaulChanceMin) or 0.18)
        + ((tonumber(config.longHaulChancePerRating) or 0.03) * (tonumber(playerRating) or 0))
    longHaulChance = math.min(0.45, math.max(0, longHaulChance))

    local localPool, allViable = buildRestaurantPools(vehiclePos, minDistance, longHaulCap)
    if #allViable == 0 then
        return nil
    end

    local restaurant = nil
    local pickupSpot = nil
    local deliverySpot = nil
    local validDistDelivery = nil
    local pickAttempts = tonumber(config.restaurantPickAttempts) or 6

    for _ = 1, pickAttempts do
        local wantLongHaul = math.random() < longHaulChance
        local pool = wantLongHaul and allViable or ((#localPool > 0) and localPool or allViable)
        local candidate = weightedPickRestaurant(pool)
        if candidate and candidate.pickupSpots and #candidate.pickupSpots > 0 then
            local pickup = candidate.pickupSpots[math.random(#candidate.pickupSpots)]
            if pickup and pickup.pos then
                local startMax = baseMaxDistance
                local absMax = localCap
                if wantLongHaul then
                    startMax = math.max(baseMaxDistance, longHaulStartMin)
                    absMax = longHaulCap
                end

                local spot, roadDist = findValidDropoff(pickup.pos, minDistance, startMax, absMax)
                if spot then
                    restaurant = candidate
                    pickupSpot = pickup
                    deliverySpot = spot
                    validDistDelivery = roadDist
                    break
                end
            end
        end
    end

    if not restaurant or not pickupSpot or not deliverySpot then
        return nil
    end

    rememberRecentRestaurant(restaurant.id)
    generateValueMultiplier()

    local distToPickup = calculateDrivingDistance(vehiclePos, pickupSpot.pos)
    -- Use the pre-calculated delivery distance if available, otherwise calculate it (should cover edge cases)
    local distDelivery = validDistDelivery or calculateDrivingDistance(pickupSpot.pos, deliverySpot.pos)
    local totalDistance = distToPickup + distDelivery -- Total trip distance

    local expectedTime = (totalDistance / config.averageSpeedMPS) + config.pickupDropoffTimeBuffer
    expectedTime = math.max(expectedTime, 60) -- Minimum 60 seconds for the whole trip

    local order = {
        restaurant = restaurant.name,
        restaurantId = restaurant.id,
        pickup = {
            pos = pickupSpot.pos,
            name = pickupSpot.name
        },
        destination = {
            pos = deliverySpot.pos,
            name = getDeliveryLocationName(deliverySpot)
        },
        expectedTime = expectedTime,
        startTime = nil
    }

    applyOrderFareFields(order, totalDistance)
    order.expectedTimeDisplay = string.format("%d min %d sec", math.floor(expectedTime / 60), math.floor(expectedTime % 60))

    return order
end

-- ================================
-- DELIVERY COMPLETION

-- Drop the player straight into the BeamEats app on the earnings summary.
-- Deferred a frame or two because the reward flow that runs right after
-- completion pushes its own UI and would win the race for the router.
local function openBeamEatsApp()
    local function navigate()
        if gameplay_phone and gameplay_phone.openRoute then
            gameplay_phone.openRoute("phone-beam-eats")
        elseif extensions and extensions.ui_router then
            extensions.ui_router.navigate("phone-beam-eats")
        end
    end

    if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
            job.sleep(0.2)
            navigate()
        end)
    else
        navigate()
    end
end

local function completeDelivery()
    if not currentOrder then
        return
    end

    local elapsedTime = timer - currentOrder.startTime
    local expectedTime = currentOrder.expectedTime
    local timeDiff = expectedTime - elapsedTime 

    local nextStreak = orderStreak + 1
    local logisticsXp = calculateLogisticsXp(currentOrder.totalDistance, nextStreak)

    local roughEvents = M.deliveryData.roughEvents or 0
    local baseFare = currentOrder.baseFare
    local smoothDrivingTip = calculateSmoothDrivingTip(baseFare, roughEvents)
    
    local timeBonus = 0
    if timeDiff >= 0 then
        timeBonus = baseFare * config.onTimeBonusPercent
    else
        -- Late penalty for tips
        -- Calculate how much the tip should drop based on lateness
        -- Random drop up to 5% per second late
        local penaltyPerSecond = 0.05
        local secondsLate = math.abs(timeDiff)
        local totalPenaltyPercent = 0
        
        for _ = 1, math.ceil(secondsLate) do
             totalPenaltyPercent = totalPenaltyPercent + (math.random() * penaltyPerSecond)
        end
        
        -- Cap penalty at 100% reduction
        totalPenaltyPercent = math.min(1.0, totalPenaltyPercent)
        
        -- Apply penalty to the smooth driving tip
        smoothDrivingTip = smoothDrivingTip * (1.0 - totalPenaltyPercent)
    end

    local streakMultiplier = math.min(orderStreak * config.streakMultiplierPerLevel, config.streakMultiplierMax)
    local streakBonus = baseFare * streakMultiplier

    local totalTips = smoothDrivingTip + timeBonus

    local finalPayment = baseFare + streakBonus + totalTips
    cumulativeReward = cumulativeReward + finalPayment
    orderStreak = orderStreak + 1

    currentOrder.totalPayment = finalPayment
    currentOrder.smoothDrivingTip = smoothDrivingTip
    currentOrder.timeBonus = timeBonus
    currentOrder.roughEvents = roughEvents
    currentOrder.totalTips = totalTips
    currentOrder.streakBonus = streakBonus

    local rating = 5.0
    rating = rating - (roughEvents * (config.roughEventRatingPenalty or 0.35))
    if timeDiff < 0 then -- Late
        rating = rating - (config.lateDeliveryRatingPenalty or 0.6)
    else
        rating = rating + (config.onTimeRatingBonus or 0.25) -- bonus for on-time delivery
    end
    rating = math.max(1.0, math.min(5.0, rating)) -- Clamp between 1 and 5
    -- Pull rating toward 5 so star average climbs faster with good deliveries
    local pull = config.ratingPullTowardFive or 0.2
    if pull > 0 then
        rating = rating + (5.0 - rating) * pull
        rating = math.max(1.0, math.min(5.0, rating))
    end
    
    local oldRating = playerRating

    ratingSum = ratingSum + rating
    ratingCount = ratingCount + 1
    
    
    local virtualStartCount = config.ratingDampeningCount or 4
    local virtualStartRating = 0.0
    
    local effectiveSum = ratingSum + (virtualStartCount * virtualStartRating)
    local effectiveCount = ratingCount + virtualStartCount
    
    playerRating = math.max(0.0, math.min(5.0, effectiveSum / effectiveCount))
    
    lastRatingDelta = playerRating - oldRating

    savePlayerRating()

    currentOrder.totalPaymentDisplay = string.format("%.2f", finalPayment)
    -- currentOrder.baseFareDisplay = string.format("%.2f", baseFare)
    currentOrder.totalTipsDisplay = string.format("%.2f", totalTips)
    currentOrder.totalDistanceDisplay = string.format("%.2f", currentOrder.totalDistance / 1000)

    state = "completed" 

    guihooks.trigger('ClearTasklist')
    guihooks.trigger('SetTasklistHeader', {label = "BeamEats Delivery Complete"})
    
    local xpMsg = ""
    if logisticsXp > 0 then
        currentOrder.streakXP = logisticsXp
        xpMsg = string.format(" | Logistics XP: +%d", logisticsXp)
    end
    
    guihooks.trigger('SetTasklistTask', {
        id = "beamEats_complete_msg",
        label = string.format("Earned: $%s%s", currentOrder.totalPaymentDisplay, xpMsg),
        done = true,
        active = true,
        type = "message",
        clear = false
    })

    -- Schedule clearing of the tasklist after 8 seconds
    -- We can't use simple 'sleep' here as we are in main thread update flow potentially
    -- We will set a timer variable that the update loop checks to clear it
    M.deliveryData.clearTasklistTimer = 8.0
    
    dataToSend = buildBeamEatsStateData()
    guihooks.trigger('updateBeamEatsState', dataToSend)

    openBeamEatsApp()
    
    local label = string.format("BeamEats delivery: $%s\nDistance: %skm | Tips: $%s", currentOrder.totalPaymentDisplay,
        currentOrder.totalDistanceDisplay, currentOrder.totalTipsDisplay)

    if not career_career or not career_career.isActive() then
        return
    end

    if career_modules_payment and type(career_modules_payment.reward) == "function" then
        
        local xpLabel = ""
        if logisticsXp > 0 then
            xpLabel = string.format("\nLogistics XP (streak %d): +%d", orderStreak, logisticsXp)
        end

        local rewardData = {
            money = {
                amount = math.floor(finalPayment)
            }
        }

        if logisticsXp > 0 then
            rewardData["logistics-delivery"] = {
                amount = logisticsXp
            }
        end

        if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
            career_modules_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
        end
        local awardedMoney = (rewardData.money and rewardData.money.amount) or math.floor(finalPayment)
        logisticsXp = (rewardData["logistics-delivery"] and rewardData["logistics-delivery"].amount) or logisticsXp
        currentOrder.totalPaymentDisplay = string.format("%.2f", awardedMoney)
        if logisticsXp > 0 then
            xpLabel = string.format("\nLogistics XP (streak %d): +%d", orderStreak, logisticsXp)
            currentOrder.streakXP = logisticsXp
        else
            xpLabel = ""
            currentOrder.streakXP = nil
        end
        local surgeText = ""
        if career_modules_activityHeat and career_modules_activityHeat.formatSurgeBonusText then
            surgeText = career_modules_activityHeat.formatSurgeBonusText(currentOrder.demandMultiplier or "beamEats")
        end
        label = string.format("BeamEats delivery: $%s%s\nDistance: %skm | Tips: $%s",
            currentOrder.totalPaymentDisplay, surgeText, currentOrder.totalDistanceDisplay, currentOrder.totalTipsDisplay) .. xpLabel
        guihooks.trigger('SetTasklistTask', {
            id = "beamEats_complete_msg",
            label = string.format("Earned: $%s%s%s", currentOrder.totalPaymentDisplay, surgeText, xpLabel),
            done = true,
            active = true,
            type = "message",
            clear = false
        })
        requestBeamEatsState()
        career_modules_payment.reward(rewardData, {
            label = label,
            tags = {"transport", "beamEats"}
        }, true)
    else
        log('W', 'beamEats', 'career_modules_payment not available, skipping reward')
    end
    if career_career.isAutosaveEnabled() then
        career_saveSystem.saveCurrent()
    end
end

local function dismissSummary()
    state = "ready"
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = calculateJobOfferInterval()
    core_groundMarkers.resetAll()
    M.deliveryData = {}
    requestBeamEatsState()
end

-- ================================
-- ORDER MANAGEMENT
-- ================================
local function rejectOrder()
    state = "ready"
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = calculateJobOfferInterval()
    requestBeamEatsState()
end

local function stopBeamEatsJob()
    state = "start"
    if currentOrder then
        core_groundMarkers.resetAll()
    end
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = calculateJobOfferInterval()
    cumulativeReward = 0
    orderStreak = 0
    M.deliveryData = {}
    guihooks.trigger('ClearTasklist') 
end

local function setAvailable()
    -- Ensure initialization if it failed/was skipped during spawn
    if #restaurants == 0 then
        pcall(findRestaurants)
    end
    if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
        pcall(findAllDeliveryParkingSpots)
    end

    state = "ready"
    requestBeamEatsState()
end

local function prepareBeamEatsJob(dt)
    if not currentOrder then
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return
    end

    local vehiclePos = vehicle:getPosition()
    local pickupDist = (vehiclePos - currentOrder.pickup.pos):length()

    if pickupDist < 5 then
    if vehicle:getVelocity():length() < config.stopVelocityThreshold then
        dwellTimer = dwellTimer + dt
        if dwellTimer < dwellDuration then
            ui_message(string.format("Picking up order... %0.1fs", dwellDuration - dwellTimer), 0.1, 'beamEats_dwell', 'timer')
            return
        end
    else
        dwellTimer = 0
        ui_message("Stop to pick up order", 1, 'beamEats_dwell', 'info')
        return
    end
        
        dwellTimer = 0
        state = "dropoff"

        M.deliveryData = {
            roughEvents = 0
        }
        core_groundMarkers.setPath(currentOrder.destination.pos, { clearPathOnReachingTarget = true })
        
        ui_message("Order picked up! Don't spill it!", 6, 'beamEats_main', 'check')

        dataToSend = buildBeamEatsStateData()
        guihooks.trigger('updateBeamEatsState', dataToSend)
    end
end

-- ================================
-- MAIN UPDATE LOOP
-- ================================
local updateInterval = 1.0
local function update(_, dt)
    timer = timer + dt
    updateTimer = updateTimer + dt
    uiUpdateTimer = uiUpdateTimer + dt

    if updateTimer >= updateInterval then
        updateTimer = 0
        requestBeamEatsState()
    end

    -- Clear tasklist timer logic
    if M.deliveryData.clearTasklistTimer then
        M.deliveryData.clearTasklistTimer = M.deliveryData.clearTasklistTimer - dt
        if M.deliveryData.clearTasklistTimer <= 0 then
            guihooks.trigger('ClearTasklist')
            M.deliveryData.clearTasklistTimer = nil
        end
    end

    if currentOrder and (state == "pickup" or state == "dropoff") then
        if state == "pickup" then
            prepareBeamEatsJob(dt)
        elseif state == "dropoff" then
            updateSensorData()
            local vehicle = be:getPlayerVehicle(0)
            if vehicle then
                local vehiclePos = vehicle:getPosition()
                local destDist = (vehiclePos - currentOrder.destination.pos):length()

                if destDist < 5 then
                    if vehicle:getVelocity():length() < config.stopVelocityThreshold then
                        dwellTimer = dwellTimer + dt
                        if dwellTimer < dwellDuration then
                            ui_message(string.format("Dropping off order... %0.1fs", dwellDuration - dwellTimer), 0.1, 'beamEats_dwell', 'timer')
                        else
                            dwellTimer = 0
                            completeDelivery()
                        end
                    else
                        dwellTimer = 0
                        ui_message("Stop to drop off order", 0.1, 'beamEats_dwell', 'info')
                    end
                else
                    dwellTimer = 0
                end
            end
        end

        if uiUpdateTimer >= 0.5 then 
            uiUpdateTimer = 0
            local elapsedTime = timer - currentOrder.startTime
            local timeLeft = math.max(0, currentOrder.expectedTime - elapsedTime)
            local timeDiff = currentOrder.expectedTime - elapsedTime 
            local totalTime = currentOrder.expectedTime
            
            local phaseLabel = (state == "pickup") and "Pickup at: " .. currentOrder.restaurant or "Deliver to: " .. (currentOrder.destination.name or "Customer")
            
            local progressPercent = (timeLeft / totalTime) * 100
            if timeDiff < 0 then progressPercent = 0 end

            local timerText = string.format("%0.0fs", timeLeft)
            if timeDiff < 0 then
                timerText = string.format("LATE: %0.0fs", math.abs(timeDiff))
            end

            guihooks.trigger('SetTasklistHeader', {label = "BeamEats Delivery"})
            
            guihooks.trigger('SetTasklistTask', {
                id = "beamEats_phase",
                label = phaseLabel,
                done = false,
                active = true,
                type = "message",
                clear = false
            })
            guihooks.trigger('SetTasklistTask', {
                id = "beamEats_timer",
                label = "Time Limit",
                subtext = timerText,
                percent = progressPercent,
                done = false,
                active = true,
                type = "goal",
                clear = false
            })
        end
    end

    if state == "ready" then
        local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
        if beamEatsDisabled then
            state = "start"
            requestBeamEatsState()
            return
        end

        jobOfferTimer = jobOfferTimer + dt
        if jobOfferTimer >= jobOfferInterval then

            jobOfferInterval = calculateJobOfferInterval()

            local newOrder = generateOrder()
            if newOrder then
                currentOrder = newOrder
                state = "incoming"
                requestBeamEatsState()

                if not ui_phone_layout and extensions and extensions.load then
                    pcall(extensions.load, "ui_phone_layout")
                end
                if ui_phone_layout and ui_phone_layout.fireNotification then
                    ui_phone_layout.fireNotification("beamEats.newOrder", {
                        title = "New Order",
                        message = newOrder.restaurant,
                        meta = string.format("$%0.2f · %0.1f km", newOrder.baseFare, newOrder.totalDistance / 1000),
                        kind = "invite",
                        ttl = 8,
                        source = "BeamEats",
                        sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
                    })
                end
            else
                jobOfferTimer = 0
                jobOfferInterval = math.random(10, 20)
            end
        end
    end
end

-- ================================
-- STATE REQUEST
-- ================================
function requestBeamEatsState()
    dataToSend = buildBeamEatsStateData()
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- DELIVERY START
-- ================================
function startDelivery(order)
    if not order then
        order = currentOrder
    end

    if not order then
        return
    end

    -- Recalculate route and time based on current position to prevent "travel before accept" exploit
    local vehicle = be:getPlayerVehicle(0)
    if vehicle then
        local vehiclePos = vehicle:getPosition()
        local distToPickup = calculateDrivingDistance(vehiclePos, order.pickup.pos)
        local distDelivery = calculateDrivingDistance(order.pickup.pos, order.destination.pos)
        
        local totalDistance = distToPickup + distDelivery
        local expectedTime = (totalDistance / config.averageSpeedMPS) + config.pickupDropoffTimeBuffer
        expectedTime = math.max(expectedTime, 60)

        order.expectedTime = expectedTime
        order.expectedTimeDisplay = string.format("%d min %d sec", math.floor(expectedTime / 60), math.floor(expectedTime % 60))
        applyOrderFareFields(order, totalDistance)
    end

    state = "pickup"
    currentOrder = order
    currentOrder.startTime = timer
    core_groundMarkers.setPath(order.pickup.pos, { clearPathOnReachingTarget = true })

    dataToSend = buildBeamEatsStateData()
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- EVENT HANDLERS
-- ================================
local function onEnterVehicleFinished()
    findRestaurants()
    findAllDeliveryParkingSpots()
    loadPlayerRating()
end

local function onVehicleSwitched()

    state = "start"
    if currentOrder then
        core_groundMarkers.resetAll()
    end
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = calculateJobOfferInterval()
    cumulativeReward = 0
    orderStreak = 0

    vehicleMultiplier = 0.1

    if be:getPlayerVehicle(0) and (not gameplay_walk or not gameplay_walk.isWalking()) then
        generateValueMultiplier()
    end
    dataToSend = buildBeamEatsStateData()
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

local function receiveSensorData(gx, gy, gz, gx2, gy2, gz2)
    processSensorData(gx, gy, gz, gx2, gy2, gz2)
end

-- ================================
-- MODULE LOADING
-- ================================
local function onExtensionLoaded()
    print("BeamEats module loaded")
    
    if be:getPlayerVehicle(0) then
        -- Use pcall to prevent extension load failure if initialization fails
        local status, err = pcall(function()
            findRestaurants()
            findAllDeliveryParkingSpots()
            loadPlayerRating()
            jobOfferInterval = calculateJobOfferInterval()
        end)
        if not status then
            log('E', 'beamEats', "Error initializing BeamEats: " .. tostring(err))
        end
    end
end

local function isBeamEatsJobActive()
    return state ~= "start" and state ~= "disabled"
end

local function onSaveCurrentProfile(currentSavePath)
    savePlayerRating(currentSavePath)
end

-- ================================
-- MODULE EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onUpdate = update
M.onVehicleSwitched = onVehicleSwitched
M.onSaveCurrentProfile = onSaveCurrentProfile

M.acceptOrder = startDelivery
M.rejectOrder = rejectOrder
M.setAvailable = setAvailable
M.stopBeamEatsJob = stopBeamEatsJob
M.generateOrder = generateOrder
M.requestBeamEatsState = requestBeamEatsState
M.isBeamEatsJobActive = isBeamEatsJobActive

M.dismissSummary = dismissSummary
M.receiveSensorData = receiveSensorData

return M
