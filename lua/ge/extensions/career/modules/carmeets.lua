local M = {}

M.dependencies = {'career_career', 'gameplay_sites_sitesManager', 'util_configListGenerator', 'gameplay_traffic', 'career_saveSystem'}

local persist = require('ge/extensions/career/modules/carmeetsPersist')

local carmeetLocations = {}
local carmeetSitesLevelId = nil
local carmeetSitesAvailable = false
local carMeetVehicles = {}
local spawnedMeetVehicles = {}
local carMeetPurchaseVehicles = {}
local pendingVehicles = {}
local usedConfigs = {}

local attendanceLevel = 1
local lastGenerationTime = 0
local generationInterval = 1800
local rsvpData = nil
local lastUpdateCheck = 0
local updateInterval = 5
local pendingInvites = {}
local playerMeetReputation = 0
local nextInviteId = 1
local joinedClubs = {}
local attendanceHistory = {}
local clubDefinitions = nil
-- Active profile path whose carmeets.json is currently loaded into memory.
-- Autosave writes to a different folder; without this guard a pre-load save
-- (or a load from the autosave target) hard-resets scene rep to 0.
local loadedSavePath = nil
-- True when in-memory carmeets state differs from last disk write for loadedSavePath.
local sceneRepDirty = false

persist.bind({
    read = function()
        return {
            lastGenerationTime = lastGenerationTime,
            rsvpData = rsvpData,
            pendingInvites = pendingInvites,
            playerMeetReputation = playerMeetReputation,
            nextInviteId = nextInviteId,
            joinedClubs = joinedClubs,
            attendanceHistory = attendanceHistory,
            loadedSavePath = loadedSavePath,
            sceneRepDirty = sceneRepDirty,
        }
    end,
    setState = function(state)
        lastGenerationTime = state.lastGenerationTime
        rsvpData = state.rsvpData
        pendingInvites = state.pendingInvites
        playerMeetReputation = state.playerMeetReputation
        nextInviteId = state.nextInviteId
        joinedClubs = state.joinedClubs
        attendanceHistory = state.attendanceHistory
        loadedSavePath = state.loadedSavePath
        sceneRepDirty = state.sceneRepDirty
    end,
    isCareerActive = function()
        return career_career and career_career.isActive and career_career.isActive()
    end,
    getActiveSavePath = function()
        local _, savePath = career_saveSystem.getCurrentProfile()
        return savePath
    end,
})

local careerActive = false
local previousTrafficAmount = nil
local getCarMeetLocations
local ensureCarmeetSitesForCurrentLevel
local getCarMeetOverview
local canPlayerSellAtMeet
local startCarMeet

local function isHardcoreMode()
    if career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode then
        return career_modules_difficultyMode.isHardcoreMode() == true
    end
    return career_career and career_career.hardcoreMode == true
end

local meetState = {
    active = false,
    type = nil,
    location = nil,
    playerSpot = nil,
    startTime = 0,
    arrivalTime = 0,
    flags = {},
    phase = "waiting"
}

-- Ground markers are shared by every career activity. Keep track of the route
-- created by car meets so meet cleanup cannot erase a newer Marketplace,
-- delivery, journal, or manually selected route.
-- Keep these helpers on one table: this file is already at LuaJIT's 200-local limit.
local meetRoute = { target = nil, token = nil }

function meetRoute.copy(target)
    if not target then return nil end
    local ok, result = pcall(function()
        return vec3(target.x, target.y, target.z)
    end)
    return ok and result or nil
end

function meetRoute.set(target, options)
    local routeTarget = meetRoute.copy(target)
    if not routeTarget or not core_groundMarkers or not core_groundMarkers.setPath then
        return false
    end
    if overhaul_groundMarkerOwnership and overhaul_groundMarkerOwnership.install then
        overhaul_groundMarkerOwnership.install()
    end
    meetRoute.token = core_groundMarkers.setPath(routeTarget, options)
    meetRoute.target = routeTarget
    return true
end

function meetRoute.clear()
    local ownedTarget = meetRoute.target
    local ownedToken = meetRoute.token
    meetRoute.target = nil
    meetRoute.token = nil
    if not ownedTarget or not core_groundMarkers then return false end

    local currentTarget = core_groundMarkers.getTargetPos and core_groundMarkers.getTargetPos() or nil
    if not currentTarget then return false end

    local ok, distance = pcall(function()
        return (currentTarget - ownedTarget):length()
    end)
    if not ok or distance > 1 then return false end

    if core_groundMarkers.clearOwnedPath then
        return core_groundMarkers.clearOwnedPath(ownedToken)
    end
    if core_groundMarkers.resetAll then
        core_groundMarkers.resetAll()
    elseif core_groundMarkers.setPath then
        core_groundMarkers.setPath(nil)
    end
    return true
end

local attendanceLevels = {
    LOW = 1,
    MEDIUM = 2,
    HIGH = 3
}

local MIN_REPUTATION = 0
local MAX_REPUTATION = 100
local EARLY_PENDING_INVITE_CAP = 3
local LATE_PENDING_INVITE_CAP = 5
local LATE_PENDING_INVITE_REP = 70
local DEFAULT_INVITE_EXPIRATION = 1200
local DEFAULT_INVITE_GENERATION_INTERVAL = 1800
local ACCEPTED_INVITE_MISS_MESSAGE = "You bailed on an accepted car meet invite."
local CLUB_DEFINITIONS_PATH = "gameplay/carmeets/clubs.json"
local BAZAAR_OFFER_TTL = 180
local DEFAULT_SELL_OFFER_INTERVAL = 120
local DEFAULT_SELL_OFFER_FIRST_CHECK = 45

local MEET_CLEANUP_DISTANCE = 100
local MEET_LEAVE_INTERVAL = 5
local VEHICLE_SPAWN_DISTANCE = 150
local VEHICLE_VISIBLE_DISTANCE = 100
local VEHICLE_UPDATE_INTERVAL = 0.25

-- Pre-spawn all meet cars hidden on RSVP accept; reveal on approach (set false to revert)
local PRESPAWN_MEET_VEHICLES_ON_ACCEPT = true
local PRESPAWN_SPAWN_STAGGER = 0.1
local PRESPAWN_UNHIDE_PER_UPDATE = 2
local WALKING_MEET_ARRIVAL_DISTANCE = 18
local PLAYER_VEHICLE_AT_MEET_DISTANCE = 25
local CLUB_OBLIGATION_WINDOW_SIZE = 3
local CLUB_OBLIGATION_REQUIRED_ATTENDANCE = 1
local CLUB_STANDING_MAX = 100
local CLUB_STANDING_WARNING_THRESHOLD = 35
local CLUB_STANDING_MISS_PENALTY = 40

local function clampReputation(value)
    return math.min(MAX_REPUTATION, math.max(MIN_REPUTATION, value or 0))
end

local function markCarmeetsDirty()
    sceneRepDirty = true
    persist.persist()
end

local function addPlayerMeetReputation(amount, reason)
    if not amount or amount == 0 then return playerMeetReputation end
    local previous = playerMeetReputation
    playerMeetReputation = clampReputation(playerMeetReputation + amount)
    print(string.format("Car meet reputation changed from %.1f to %.1f (%s)", previous, playerMeetReputation, reason or "unknown"))
    markCarmeetsDirty()
    return playerMeetReputation
end

local function ensureVehiclePopularity()
    if not career_modules_vehiclePopularity and extensions and extensions.load then
        extensions.load("career_modules_vehiclePopularity")
    end
    return career_modules_vehiclePopularity
end

local function getMeetVehicleInventoryId(state)
    state = state or meetState
    if not state or not state.flags then return nil end
    if state.flags.saleInventoryId then return state.flags.saleInventoryId end
    if state.flags.playerBroughtVehicle then
        return getCurrentInventoryId()
    end
    return nil
end

local function appendMeetSceneEvent(inventoryId, entry)
    local popularity = ensureVehiclePopularity()
    if popularity and popularity.appendSceneEvent then
        popularity.appendSceneEvent(inventoryId, entry)
    end
end

local function awardCarRep(inventoryId, amount, reason)
    local popularity = ensureVehiclePopularity()
    if popularity and popularity.addCarRep then
        return popularity.addCarRep(inventoryId, amount, reason)
    end
end

local function addPlayerMeetReputationForVehicle(amount, inventoryId, reason)
    if not amount or amount == 0 then return playerMeetReputation, 1 end
    local multiplier = 1
    if amount > 0 and inventoryId then
        local popularity = ensureVehiclePopularity()
        if popularity and popularity.getPlayerRepMultiplier then
            multiplier = popularity.getPlayerRepMultiplier(inventoryId) or 1
        end
    end
    local adjusted = amount * multiplier
    addPlayerMeetReputation(adjusted, reason)
    return playerMeetReputation, multiplier, adjusted
end

local function getPlayerReferencePosition()
    local playerVeh = be:getPlayerVehicle(0)
    if playerVeh then return playerVeh:getPosition() end
    if core_camera and core_camera.getPosition then return vec3(core_camera.getPosition()) end
    return nil
end

local function getPendingInviteCap()
    return playerMeetReputation >= LATE_PENDING_INVITE_REP and LATE_PENDING_INVITE_CAP or EARLY_PENDING_INVITE_CAP
end

local function normalizeString(value)
    return string.lower(tostring(value or ""))
end

local function valueMatches(value, expectedValues)
    local normalized = normalizeString(value)
    if normalized == "" then return false end
    for _, expected in ipairs(expectedValues or {}) do
        local expectedNormalized = normalizeString(expected)
        if normalized == expectedNormalized or string.find(normalized, expectedNormalized, 1, true) then
            return true
        end
    end
    return false
end

local function sortedStableSerialize(value)
    local valueType = type(value)
    if valueType ~= "table" then
        return tostring(value)
    end

    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, tostring(key) .. "=" .. sortedStableSerialize(value[key]))
    end
    return "{" .. table.concat(parts, "|") .. "}"
end

local function getCurrentInventoryId()
    if career_modules_inventory and career_modules_inventory.getCurrentVehicle then
        return career_modules_inventory.getCurrentVehicle()
    end
    if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
        return career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
    end
    return nil
end

local function resolveMeetSaleInventoryId()
    local inventoryId = getCurrentInventoryId()
    if inventoryId then return inventoryId end

    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId >= 0 and career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
        inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehId)
        if inventoryId then return inventoryId end
    end

    if career_modules_inventory and career_modules_inventory.getLastVehicle then
        return career_modules_inventory.getLastVehicle()
    end
    return nil
end

local function getInventoryVehicle(inventoryId)
    if not inventoryId or not career_modules_inventory then return nil end
    if career_modules_inventory.getVehicle then
        return career_modules_inventory.getVehicle(inventoryId)
    end
    local vehicles = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()
    return vehicles and vehicles[inventoryId] or nil
end

local function getInventoryVehicleValue(inventoryId)
    if not inventoryId or not career_modules_valueCalculator then return 0 end
    local value = career_modules_valueCalculator.getInventoryVehicleValue and career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
    if not value and career_modules_valueCalculator.getInventoryVehicleSellValue then
        value = career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
    end
    return tonumber(value) or 0
end

local function getInventoryVehicleDisplayName(vehicle, fallback)
    local raw = vehicle and (vehicle.niceName or vehicle.name) or nil
    if core_locales and core_locales.translateWithOrWithoutContext and raw ~= nil then
        local translated = core_locales.translateWithOrWithoutContext(raw)
        if type(translated) == "string" and translated ~= "" then
            return translated
        end
    end
    if type(raw) == "string" and raw ~= "" then
        return raw
    end
    return fallback or "Your vehicle"
end

local function ensureMeetSaleState(state)
    if not state or not state.flags or not state.flags.saleInventoryId then return nil end
    local inventoryId = state.flags.saleInventoryId
    local vehicle = getInventoryVehicle(inventoryId) or {}
    local marketValue = getInventoryVehicleValue(inventoryId)

    state.flags.saleOffers = state.flags.saleOffers or {}
    state.flags.saleListing = state.flags.saleListing or {
        id = inventoryId,
        inventoryId = inventoryId,
        niceName = getInventoryVehicleDisplayName(vehicle, "Brought vehicle"),
        value = marketValue,
        marketValue = marketValue,
        thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil
    }

    state.flags.saleListing.niceName = getInventoryVehicleDisplayName(vehicle, state.flags.saleListing.niceName or "Brought vehicle")
    state.flags.saleListing.value = tonumber(state.flags.saleListing.value) or marketValue
    state.flags.saleListing.marketValue = marketValue
    return state.flags.saleListing
end

local function getAskingPriceOfferChanceMultiplier(listing)
    if not listing then return 1 end
    local marketValue = math.max(tonumber(listing.marketValue) or 0, 1)
    local askingRatio = (tonumber(listing.value) or marketValue) / marketValue
    if askingRatio <= 0.85 then return 1.5 end
    if askingRatio <= 1.10 then return 1.0 end
    if askingRatio <= 1.35 then return 0.7 end
    if askingRatio <= 1.60 then return 0.45 end
    return 0.25
end

local function generateMeetSaleOffer(state, ttl)
    local listing = ensureMeetSaleState(state)
    if not listing or not career_modules_marketplace or not career_modules_marketplace.generatePersonality then return nil end
    local buyerPersonality = career_modules_marketplace.generatePersonality(true)
    if not buyerPersonality then return nil end

    local marketValue = math.max(tonumber(listing.marketValue) or tonumber(listing.value) or 0, 50)
    local askingPrice = math.max(tonumber(listing.value) or marketValue, 50)
    local askingRatio = askingPrice / marketValue
    local personalityMult = buyerPersonality.priceMultiplier or 1
    local noise = 0.86 + (math.random() * 0.22)
    local askInfluence = math.max(0.85, math.min(1.12, 1 + ((askingRatio - 1) * 0.22)))
    local cap = askingRatio > 1.1 and (marketValue * math.min(1.25, 0.95 + ((askingRatio - 1) * 0.35))) or askingPrice * 1.03
    local value = math.max(50, math.floor((math.min(marketValue * personalityMult * noise * askInfluence, cap) + 25) / 50) * 50)
    local offer = {
        timestamp = os.time(),
        value = value,
        ttl = ttl or BAZAAR_OFFER_TTL,
        negotiationPossible = true,
        buyerPersonality = buyerPersonality,
        source = "carMeet"
    }
    table.insert(state.flags.saleOffers, offer)
    return offer
end

local function getSellOfferChance(meetTypeKey)
    if meetTypeKey == "SHOWCASE" then return 0.20 end
    if meetTypeKey == "CLUB" then return 0.20 end
    if meetTypeKey == "STREET_CRUISE" then return 0.20 end
    if meetTypeKey == "ELITE" then return 0.15 end
    return 0.10
end

local function getConfigKeyFromPath(configPath)
    if type(configPath) ~= "string" then return nil end
    local normalized = configPath:gsub("\\", "/")
    local key = normalized:match("/configurations/([^/]+)%.pc$")
    if key then return key end
    return normalized:match("/([^/]+)%.pc$")
end

local function applyRandomPaintToSpawnOptions(options, modelKey, configPath)
    if not options or not modelKey then return end
    if not core_vehiclePaints or not core_vehiclePaints.getRandomPaints then return end

    local paintResult = core_vehiclePaints.getRandomPaints(modelKey, getConfigKeyFromPath(configPath))
    if type(paintResult) ~= "table" then return end

    local modelData = core_vehicles.getModel(modelKey)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return end

    local paintNames = {
        paintResult.paintName1,
        paintResult.paintName2 or paintResult.paintName1,
        paintResult.paintName3 or paintResult.paintName2 or paintResult.paintName1
    }
    if not paintNames[1] or not modelPaints[paintNames[1]] then return end

    -- Use the same random-paint source as the auction house, but apply all paint
    -- slots so two-tone and three-paint configs vary properly at meets.
    options.paintName = paintNames[1]
    options.paintName2 = paintNames[2]
    options.paintName3 = paintNames[3]
    options.paint = deepcopy(modelPaints[paintNames[1]])
    options.paint2 = paintNames[2] and modelPaints[paintNames[2]] and deepcopy(modelPaints[paintNames[2]]) or nil
    options.paint3 = paintNames[3] and modelPaints[paintNames[3]] and deepcopy(modelPaints[paintNames[3]]) or nil
    options.carMeetRandomPaintNames = paintNames

    if type(configPath) == "string" then
        local cfg = jsonReadFile(configPath)
        if type(cfg) == "table" and cfg.format ~= 4 then
            cfg = deepcopy(cfg)
            cfg.partConfigFilename = configPath
            cfg.colors = nil
            local paints = type(cfg.paints) == "table" and deepcopy(cfg.paints) or {}
            paints[1] = deepcopy(options.paint)
            if options.paint2 then paints[2] = deepcopy(options.paint2) end
            if options.paint3 then paints[3] = deepcopy(options.paint3) end
            cfg.paints = paints
            options.config = cfg
        end
    end
end

local function embedPaintNamesInVehicleConfig(vehId, modelKey, paintNames)
    if not vehId or type(paintNames) ~= "table" or not paintNames[1] then return end
    if not core_vehicle_manager or not core_vehicle_manager.setVehiclePaintsNames then return end

    core_vehicle_manager.setVehiclePaintsNames(vehId, paintNames)

    local vehicleData = core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or type(vehicleData.config) ~= "table" then return end

    local modelData = modelKey and core_vehicles.getModel(modelKey) or nil
    if not modelData and vehicleData.ioCtx and vehicleData.ioCtx.modelKey then
        modelData = core_vehicles.getModel(vehicleData.ioCtx.modelKey)
    end
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return end

    local config = vehicleData.config
    config.colors = nil
    local paints = type(config.paints) == "table" and deepcopy(config.paints) or {}
    for i, paintName in ipairs(paintNames) do
        if paintName and modelPaints[paintName] then
            paints[i] = deepcopy(modelPaints[paintName])
        end
    end
    config.paints = paints
    config.paintName = paintNames[1]
    config.paintName2 = paintNames[2]
    config.paintName3 = paintNames[3]
end

local function applyRandomPaintToSpawnedVehicle(vehId, paintNames, modelKey)
    embedPaintNamesInVehicleConfig(vehId, modelKey, paintNames)
end

local function buildCarMeetVehicleShopInfo(vehicleData, spot, meetTypeKey)
    if not vehicleData then return nil end
    local info = deepcopy(vehicleData.info or {})
    local currentYear = tonumber(os.date("%Y")) or 2026
    local year, mileageMeters = currentYear, math.random(10000, 300000) * 1609.344
    if type(info.Years) == "table" then
        local minYear = tonumber(info.Years.min) or tonumber(info.Years[1])
        local maxYear = tonumber(info.Years.max) or minYear
        if minYear and maxYear then
            if minYear > maxYear then minYear, maxYear = maxYear, minYear end
            maxYear = math.min(maxYear, currentYear)
            if minYear > maxYear then minYear = maxYear end
            year = math.random(math.floor(minYear), math.floor(maxYear))
        end
    elseif tonumber(info.Years) then
        year = tonumber(info.Years)
    end
    local rawMileage = tonumber(info.Mileage) or tonumber(info.mileage) or tonumber(info["Mileage"])
    if rawMileage and rawMileage > 0 then
        mileageMeters = rawMileage > 2000000 and rawMileage or rawMileage * 1609.344
    end
    local catalogValue = tonumber(info.Value) or tonumber(info.value) or tonumber(info.configBaseValue) or 10000
    local marketValue = nil
    local configKey = tostring(info.key or vehicleData.config or ""):match("/configurations/([^/]+)%.pc$") or tostring(info.key or ""):gsub("%.pc$", "")
    local partsCatalogSum = info.cachedPartsValue
    if not partsCatalogSum and career_modules_valueCalculator and career_modules_valueCalculator.getVehiclePcPartsCatalogSum then
        partsCatalogSum = career_modules_valueCalculator.getVehiclePcPartsCatalogSum(info.model_key or vehicleData.model, configKey, "carMeetPurchase")
    end
    if career_modules_valueCalculator and career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue then
        marketValue = career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
            catalogBaseValue = catalogValue,
            mileageMeters = mileageMeters,
            age = math.max(0, currentYear - (tonumber(year) or currentYear)),
            modelName = info.model_key or vehicleData.model,
            configKey = configKey,
            partsCatalogSum = partsCatalogSum,
            logContext = "carMeetPurchase",
            applyVehicleBuyMarket = false
        })
    end
    if not marketValue and career_modules_valueCalculator and career_modules_valueCalculator.getAdjustedVehicleBaseValue then
        marketValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(catalogValue, {mileage = mileageMeters, age = math.max(0, currentYear - year)})
    end
    marketValue = math.max(1500, math.floor(tonumber(marketValue) or catalogValue))
    info.model_key = info.model_key or vehicleData.model
    info.key = vehicleData.config
    info.Name = info.Name or info.name or info.key or "Meet Vehicle"
    info.Brand = info.Brand or info.brand or info.model_key or "Car Meet"
    info.niceName = (info.Brand and info.Name) and (tostring(info.Brand) .. " " .. tostring(info.Name)) or "Car Meet Vehicle"
    info.Value = marketValue
    info.marketValue = marketValue
    info.marketValueBase = info.marketValue
    info.valueBase = nil
    info.Mileage = mileageMeters
    info.year = year
    info.fees = 0
    info.tax = 0
    info.sellerId = "carMeet"
    if career_modules_marketplace and career_modules_marketplace.generatePersonality then
        info.negotiationPersonality = career_modules_marketplace.generatePersonality(false)
    end
    info.sellerName = info.negotiationPersonality and info.negotiationPersonality.name or "Private Seller"
    info.negotiationPossible = true
    info.playerStartsNegotiation = true
    info.hideMarketValue = true
    info.source = "carMeet"
    info.meetType = meetTypeKey
    info.pos = spot and vec3(spot.pos) or nil
    return info
end

local function loadClubDefinitions()
    if clubDefinitions then return clubDefinitions end
    local data = jsonReadFile(CLUB_DEFINITIONS_PATH) or {}
    clubDefinitions = data.clubs or {}
    return clubDefinitions
end

local function getClubDefinition(clubId)
    clubId = tostring(clubId or "")
    for _, club in ipairs(loadClubDefinitions()) do
        if tostring(club.id) == clubId then
            return club
        end
    end
    return nil
end

local function getPlayerMoney()
    if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
        return tonumber(career_modules_playerAttributes.getAttributeValue("money")) or 0
    end
    return 0
end

local function clubRequirementText(requirements)
    requirements = requirements or {}
    if requirements.minVehicleValue then
        return "Vehicle value: $" .. tostring(requirements.minVehicleValue) .. "+"
    end
    if requirements.models and #requirements.models > 0 then
        return "Models: " .. table.concat(requirements.models, ", ")
    end
    if requirements.brands and #requirements.brands > 0 then
        return "Brands: " .. table.concat(requirements.brands, ", ")
    end
    if requirements.tags and #requirements.tags > 0 then
        return "Tags: " .. table.concat(requirements.tags, ", ")
    end
    return "Any owned vehicle"
end

local function vehicleMatchesClub(vehicle, club, inventoryId)
    if not vehicle or not club then return false end
    local requirements = club.requirements or {}
    if requirements.minVehicleValue then
        local vehicleValue = getInventoryVehicleValue(inventoryId)
        if vehicleValue <= 0 and vehicle.id then
            vehicleValue = getInventoryVehicleValue(vehicle.id)
        end
        if vehicleValue <= 0 then
            vehicleValue = tonumber(vehicle.value) or tonumber(vehicle.Value) or tonumber(vehicle.configBaseValue) or 0
        end
        if vehicleValue < tonumber(requirements.minVehicleValue) then return false end
    end
    local modelValues = {
        vehicle.model,
        vehicle.modelName,
        vehicle.config and vehicle.config.model,
        vehicle.config and vehicle.config.model_key,
        vehicle.config and vehicle.config.mainPartName
    }
    if requirements.models and #requirements.models > 0 then
        for _, value in pairs(modelValues) do
            if valueMatches(value, requirements.models) then return true end
        end
        return false
    end

    local brandValues = {
        vehicle.Brand,
        vehicle.brand,
        vehicle.config and vehicle.config.Brand,
        vehicle.config and vehicle.config.brand,
        vehicle.niceName
    }
    if requirements.brands and #requirements.brands > 0 then
        for _, value in pairs(brandValues) do
            if valueMatches(value, requirements.brands) then return true end
        end
        return false
    end

    if requirements.tags and #requirements.tags > 0 then
        local haystackParts = {}
        local function addHaystackPart(value)
            if value then table.insert(haystackParts, tostring(value)) end
        end
        addHaystackPart(vehicle.model)
        addHaystackPart(vehicle.niceName)
        if vehicle.config then
            addHaystackPart(vehicle.config.partConfigFilename)
            addHaystackPart(vehicle.config.configType)
            addHaystackPart(vehicle.config["Config Type"])
            addHaystackPart(vehicle.config["Body Style"])
            if vehicle.config.tags then
                addHaystackPart(sortedStableSerialize(vehicle.config.tags))
            end
        end
        local haystack = normalizeString(table.concat(haystackParts, " "))
        for _, tag in ipairs(requirements.tags) do
            if not string.find(haystack, normalizeString(tag), 1, true) then
                return false
            end
        end
        return true
    end

    return true
end

local function getVehicleInfoFieldText(vehicleInfo)
    if not vehicleInfo then return "" end
    local parts = {}
    local function add(value)
        if value ~= nil then
            table.insert(parts, tostring(value))
        end
    end
    local keys = {
        "model_key", "key", "Brand", "brand", "Make", "make", "Name", "name",
        "Configuration", "Description", "Config Type", "ConfigType", "Body Style",
        "BodyStyle", "Body", "Type", "Source", "defaultPaintName1"
    }
    for _, key in ipairs(keys) do
        add(vehicleInfo[key])
    end
    if type(vehicleInfo.Years) == "table" then
        add(vehicleInfo.Years.min)
        add(vehicleInfo.Years.max)
        add(vehicleInfo.Years[1])
        add(vehicleInfo.Years[2])
    else
        add(vehicleInfo.Years)
    end
    if type(vehicleInfo.tags) == "table" then add(sortedStableSerialize(vehicleInfo.tags)) end
    if type(vehicleInfo.Tags) == "table" then add(sortedStableSerialize(vehicleInfo.Tags)) end
    return normalizeString(table.concat(parts, " "))
end

local function getVehicleInfoYearBounds(vehicleInfo)
    if not vehicleInfo then return nil, nil end
    local years = vehicleInfo.Years or vehicleInfo.Year or vehicleInfo.year
    if type(years) == "table" then
        local minYear = tonumber(years.min) or tonumber(years[1])
        local maxYear = tonumber(years.max) or tonumber(years[2]) or minYear
        if minYear and maxYear and minYear > maxYear then
            minYear, maxYear = maxYear, minYear
        end
        return minYear, maxYear
    end
    local year = tonumber(years)
    return year, year
end

local function vehicleInfoMatchesClassicMuscle(vehicleInfo)
    local haystack = getVehicleInfoFieldText(vehicleInfo)
    local brand = vehicleInfo and (vehicleInfo.Brand or vehicleInfo.brand or vehicleInfo.Make or vehicleInfo.make) or ""
    local body = normalizeString(vehicleInfo and (vehicleInfo["Body Style"] or vehicleInfo.BodyStyle or vehicleInfo.Body) or "")
    local minYear, maxYear = getVehicleInfoYearBounds(vehicleInfo)
    local american = valueMatches(brand, {"Bruckell", "Gavril", "Burnside", "Soliad"}) or string.find(haystack, "american", 1, true) ~= nil
    local oldEnough = (maxYear and maxYear <= 1975) or string.find(haystack, "classic", 1, true) ~= nil
    local bodyOk = string.find(body, "coupe", 1, true) ~= nil
        or string.find(body, "sedan", 1, true) ~= nil
        or string.find(haystack, "coupe", 1, true) ~= nil
        or string.find(haystack, "sedan", 1, true) ~= nil
    local vibeOk = string.find(haystack, "muscle", 1, true) ~= nil
        or string.find(haystack, "classic", 1, true) ~= nil
        or string.find(haystack, "street", 1, true) ~= nil
        or string.find(haystack, "custom", 1, true) ~= nil
    return american and bodyOk and (oldEnough or vibeOk)
end

local function vehicleInfoMatchesClub(vehicleInfo, club)
    if not vehicleInfo or not club then return false end
    if club.id == "classic_muscle_crew" and vehicleInfoMatchesClassicMuscle(vehicleInfo) then
        return true
    end

    local requirements = club.requirements or {}
    if requirements.minVehicleValue then
        local value = tonumber(vehicleInfo.Value) or tonumber(vehicleInfo.value) or tonumber(vehicleInfo.configBaseValue) or 0
        if value < tonumber(requirements.minVehicleValue) then return false end
    end
    if requirements.models and #requirements.models > 0 then
        local modelValues = {
            vehicleInfo.model_key,
            vehicleInfo.model,
            vehicleInfo.Model,
            vehicleInfo.key,
            vehicleInfo.Name,
            vehicleInfo.name
        }
        for _, value in pairs(modelValues) do
            if valueMatches(value, requirements.models) then return true end
        end
        return false
    end

    if requirements.brands and #requirements.brands > 0 then
        local brandValues = {
            vehicleInfo.Brand,
            vehicleInfo.brand,
            vehicleInfo.Make,
            vehicleInfo.make,
            vehicleInfo.Name,
            vehicleInfo.name
        }
        for _, value in pairs(brandValues) do
            if valueMatches(value, requirements.brands) then return true end
        end
        return false
    end

    if requirements.tags and #requirements.tags > 0 then
        local haystack = getVehicleInfoFieldText(vehicleInfo)
        for _, tag in ipairs(requirements.tags) do
            if not string.find(haystack, normalizeString(tag), 1, true) then
                return false
            end
        end
        return true
    end

    return true
end

local function getVehicleInfoPopulation(vehicleInfo)
    if not vehicleInfo then return math.huge end
    local population = tonumber(vehicleInfo.Population) or tonumber(vehicleInfo.population) or tonumber(vehicleInfo.adjustedPopulation)
    if not population or population <= 0 then return math.huge end
    return population
end

local function getVehicleInfoCatalogValue(vehicleInfo)
    if not vehicleInfo then return 0 end
    return tonumber(vehicleInfo.Value) or tonumber(vehicleInfo.value) or tonumber(vehicleInfo.configBaseValue) or 0
end

local function vehicleInfoMatchesPoolRules(vehicleInfo, rules)
    if not rules then return true end
    local population = getVehicleInfoPopulation(vehicleInfo)
    local value = getVehicleInfoCatalogValue(vehicleInfo)
    if rules.populationMax and population > rules.populationMax then return false end
    if rules.valueMin and value < rules.valueMin then return false end
    return true
end

local function filterVehicleInfosForPoolRules(vehicleInfos, rules)
    if not rules then return vehicleInfos end
    local filtered = {}
    for _, vehicleInfo in ipairs(vehicleInfos or {}) do
        if vehicleInfoMatchesPoolRules(vehicleInfo, rules) then
            table.insert(filtered, vehicleInfo)
        end
    end
    return filtered
end

local function getMeetVehiclePoolRules(meetType)
    local rules = meetType and meetType.vehiclePoolRules
    if not rules then return nil end
    local tiers = rules.tiers or {rules}
    return tiers
end

local function playerOwnsClubVehicle(club)
    if not career_modules_inventory or not career_modules_inventory.getVehicles then return false end
    for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
        if vehicleMatchesClub(vehicle, club, inventoryId) then
            return true
        end
    end
    return false
end

local function isClubJoined(clubId)
    return joinedClubs[tostring(clubId)] ~= nil
end

local function isClubActive(club)
    return club and isClubJoined(club.id) and playerOwnsClubVehicle(club)
end

local function ensureClubMembership(clubId)
    clubId = tostring(clubId or "")
    local membership = joinedClubs[clubId]
    if not membership then return nil end
    if type(membership) ~= "table" then
        membership = {joinedAt = os.time()}
        joinedClubs[clubId] = membership
    end
    membership.joinedAt = membership.joinedAt or os.time()
    membership.standing = tonumber(membership.standing) or CLUB_STANDING_MAX
    membership.obligationEvents = tonumber(membership.obligationEvents) or 0
    membership.obligationAttended = tonumber(membership.obligationAttended) or 0
    membership.obligationWindowSize = tonumber(membership.obligationWindowSize) or CLUB_OBLIGATION_WINDOW_SIZE
    membership.requiredAttendance = tonumber(membership.requiredAttendance) or CLUB_OBLIGATION_REQUIRED_ATTENDANCE
    return membership
end

local function recordClubMeetResult(clubId, attended, reason)
    local membership = ensureClubMembership(clubId)
    if not membership then return end

    membership.obligationEvents = (tonumber(membership.obligationEvents) or 0) + 1
    if attended then
        membership.obligationAttended = (tonumber(membership.obligationAttended) or 0) + 1
        membership.lastAttendedAt = os.time()
    else
        membership.lastMissedAt = os.time()
    end

    if membership.obligationEvents < (membership.obligationWindowSize or CLUB_OBLIGATION_WINDOW_SIZE) then
        return
    end

    local club = getClubDefinition(clubId)
    local clubName = club and club.name or "your club"
    local missedRequirement = (tonumber(membership.obligationAttended) or 0) < (membership.requiredAttendance or CLUB_OBLIGATION_REQUIRED_ATTENDANCE)
    membership.obligationEvents = 0
    membership.obligationAttended = 0

    if not missedRequirement then
        markCarmeetsDirty()
        return
    end

    membership.standing = math.max(0, (tonumber(membership.standing) or CLUB_STANDING_MAX) - CLUB_STANDING_MISS_PENALTY)
    -- Club standing can drop, but scene reputation only drops on Car Bazaar RSVP miss.

    if membership.standing <= 0 then
        joinedClubs[tostring(clubId)] = nil
        ui_message("You lost standing with " .. clubName .. " and need to re-pay dues to rejoin.", 9, "warning", "warning")
    elseif membership.standing <= CLUB_STANDING_WARNING_THRESHOLD then
        ui_message(clubName .. " standing is low. Attend an upcoming club meet to avoid being dropped.", 9, "warning", "warning")
    else
        ui_message("You missed your " .. clubName .. " attendance requirement.", 7, "warning", "warning")
    end
    markCarmeetsDirty()
end

local function getActiveClubs(includeSpecial)
    local activeClubs = {}
    for _, club in ipairs(loadClubDefinitions()) do
        if isClubActive(club) and (includeSpecial or club.type ~= "special") then
            table.insert(activeClubs, club)
        end
    end
    return activeClubs
end

local function getActiveClubById(clubId)
    if not clubId then return nil end
    clubId = tostring(clubId)
    for _, club in ipairs(loadClubDefinitions()) do
        if tostring(club.id) == clubId then
            return isClubActive(club) and club or nil
        end
    end
    return nil
end

local function selectActiveClub(clubId, allowFallback)
    local club = getActiveClubById(clubId)
    if club then return club end
    if clubId and allowFallback == false then return nil end
    local activeClubs = getActiveClubs()
    if #activeClubs == 0 then return nil end
    return activeClubs[math.random(#activeClubs)]
end

local function saveAndReduceTraffic(reductionPercent)
    if gameplay_traffic then
        previousTrafficAmount = gameplay_traffic.getNumOfTraffic()
        local newAmount = math.floor(previousTrafficAmount * (1 - reductionPercent))
        gameplay_traffic.setActiveAmount(newAmount)
    end
end

local function restoreTrafficAmount()
    if gameplay_traffic and previousTrafficAmount then
        local settingsAmount = settings.getValue('trafficAmount') == 0 and getMaxVehicleAmount() or
                               settings.getValue('trafficAmount')
        local trafficAmount = settingsAmount or previousTrafficAmount
        local pooledAmount = settings.getValue('trafficExtraAmount') or 0
        gameplay_traffic.setActiveAmount(trafficAmount + pooledAmount, trafficAmount)
        previousTrafficAmount = nil
    end
end

canPlayerSellAtMeet = function(state)
    state = state or meetState
    return state
        and state.flags
        and state.flags.playerBroughtVehicle == true
        and state.flags.saleInventoryId
        and state.flags.playerSoldSaleVehicle ~= true
end

-- Drop sale interaction markers as soon as showcase ends so they cannot linger/follow the player.
local function clearMeetShowcasePois(state)
    if state and state.flags then
        state.flags.saleVehicleId = nil
    end
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
end

local meetTypes = {
    SHOWCASE = {
        name = "Showcase",
        description = "Show off your ride and admire others",
        unlockReputation = 0,
        expirationSeconds = DEFAULT_INVITE_EXPIRATION,
        missPenalty = 0,
        requiresVehicle = false,
        baseReputationMultiplier = 1.0,
        showcaseDuration = 600,
        preferredTimes = {0.417, 0.458, 0.500},
        timeWindow = 0.02,
        vehicleFilters = {
            whiteList = {
                ["Config Type"] = {"CarmeetRLS", "Custom"},
                ["Body Style"] = {"Sedan", "Hatchbook", "SUV", "Coupe"}
            }
        },
        actions = {
            onArrival = function(reputation)
                return "Welcome to the showcase!\nCommunity liked your car!\nVehicle value increased by " .. reputation .. "%"
            end,
            onShowcaseEnd = function(state)
                state.phase = "ending"
                state.flags.dispersalStarted = false
                clearMeetShowcasePois(state)
                ui_message("Car meet is over, vehicles starting to leave!", 10, "info", "info")
            end,
            onLeave = function()
                return "Car meet is over, Thanks for coming!"
            end
        },
        onUpdate = nil
    },
    STREET_CRUISE = {
        name = "Cruise",
        description = "Meet up and cruise to a destination",
        unlockReputation = 10,
        expirationSeconds = DEFAULT_INVITE_EXPIRATION,
        missPenalty = 0,
        requiresVehicle = false,
        requiresActiveClub = false,
        baseReputationMultiplier = 1.5,
        showcaseDuration = 600,
        preferredTimes = {0.875, 0.917, 0.958},
        timeWindow = 0.025,
        vehicleFilters = {
            whiteList = {
                ["Body Style"] = {"Coupe", "Sedan", "Hatchback"}
            }
        },
        vehiclePoolRules = {
            tiers = {
                {populationMax = 5000},
                {populationMax = 10000}
            }
        },
        actions = {
            onArrival = function(reputation)
                saveAndReduceTraffic(0.7)
                return "Ready to cruise!\nCruisers respect your ride!\nCommunity reputation increased by " .. reputation .. "%"
            end,
            onShowcaseEnd = function(state)
                state.phase = "cruise"
                state.flags.cruiseStarted = false
                state.flags.playerReachedDestination = false
                state.flags.cruiseDestinationRadius = 15
                clearMeetShowcasePois(state)
            end,
            onLeave = function()
                core_jobsystem.create(function(job)
                    job.sleep(10)
                    restoreTrafficAmount()
                end)
                return "Cruise complete! Drive safe out there!"
            end
        },
        onUpdate = function(state, currentTime)
            local function getAiPath(path, vehIndex)
                local aiPath = {}
                local veh = be:getObject(vehIndex)
                if not veh then return nil end
                local firstWpAdded = false
                local vehPos = veh:getPosition()
                local vehFwd = veh:getDirectionVector()
                local bestWp = nil
                local bestDist = math.huge
                local prevDot = nil
                local prevWp = nil
                local startDist = path[1] and path[1].distToTarget or 0
                local firstValidWp = nil
                -- find the first valid waypoint
                for _, marker in ipairs(path) do
                    if marker.wp then
                        firstValidWp = marker.wp
                        if not firstWpAdded then
                            local toWp = (marker.pos - vehPos):normalized()
                            local dot = toWp:dot(vehFwd)
                            -- If we have a previous dot product and this one is lower, we found our local maximum
                            if prevDot and dot < prevDot and prevDot > 0 then
                                table.insert(aiPath, prevWp)
                                firstWpAdded = true
                            end
                            prevDot = dot
                            prevWp = marker.wp
                        else
                            table.insert(aiPath, marker.wp)
                        end
                    end
                end
                -- If we haven't found a local maximum but have a positive dot product, use the last one
                if not firstWpAdded and prevDot and prevDot > 0 then
                    table.insert(aiPath, prevWp)
                    firstWpAdded = true
                end
                -- fallback: if no waypoint is in front of vehicle, use the first waypoint that's 25m away and all other waypoints
                if not firstWpAdded then
                    for _, marker in ipairs(path) do
                        if marker.wp and startDist - marker.distToTarget > 25 then
                            table.insert(aiPath, marker.wp)
                        end
                    end
                end
                return aiPath
            end
            
            if state.phase == "cruise" then
                if not state.flags.cruiseStarted then
                    -- Find a cruise destination first
                    local function getCruiseDestination(meetLocation)
                        if not meetLocation then return nil end
                        
                        local meetCenter = meetLocation.position
                        local minDistance = 2000
                        local maxDistance = 20000
                        
                        local otherMeets = M.getCarMeetLocations()
                        local validDestinations = {}
                        
                        for name, location in pairs(otherMeets) do
                            if name ~= meetLocation.zone.name then
                                local distance = (location.position - meetCenter):length()
                                if distance >= minDistance and distance <= maxDistance then
                                    table.insert(validDestinations, location.position)
                                end
                            end
                        end
                        
                        if #validDestinations > 0 then
                            return validDestinations[math.random(#validDestinations)]
                        end
                        
                        local mapData = map.getMap()
                        if mapData and mapData.nodes then
                            local validNodes = {}
                            
                            for nodeId, node in pairs(mapData.nodes) do
                                if node.pos then
                                    local distance = (node.pos - meetCenter):length()
                                    if distance >= minDistance and distance <= maxDistance then
                                        table.insert(validNodes, node.pos)
                                    end
                                end
                            end
                            
                            if #validNodes > 0 then
                                return validNodes[math.random(#validNodes)]
                            end
                        end
                        
                        return nil
                    end
                    
                    state.flags.cruiseDestination = getCruiseDestination(state.location)
                    if state.flags.cruiseDestination then
                        local message = "Follow the cruise route with the group!"
                        ui_message(message, 10, "info", "info")
                        
                        -- Set ground markers to show the cruise route
                        local options = {
                            color = {0, 1, 0.4},
                            step = 4,
                            renderDecals = true
                        }
                        meetRoute.set(state.flags.cruiseDestination, options)
                        
                        -- Wait a moment for the route to be set up, then use it for AI
                        core_jobsystem.create(function(job)
                            job.sleep(1.0) -- Wait for route planner to process
                            
                            local rp = core_groundMarkers.routePlanner
                            if rp and rp.path and #rp.path > 0 then
                                -- Get route start position for distance calculations
                                local routeStartPos = rp.path[1] and rp.path[1].pos or state.flags.cruiseDestination
                                
                                -- Create a table of vehicles with their distances to route start
                                local vehicleDistances = {}
                                for _, vehID in ipairs(spawnedMeetVehicles) do
                                    local veh = getObjectByID(vehID)
                                    if veh then
                                        local vehPos = veh:getPosition()
                                        local distance = (vehPos - routeStartPos):length()
                                        table.insert(vehicleDistances, {
                                            id = vehID,
                                            vehicle = veh,
                                            distance = distance
                                        })
                                    end
                                end
                                
                                -- Sort vehicles by distance (closest first)
                                table.sort(vehicleDistances, function(a, b)
                                    return a.distance < b.distance
                                end)
                                
                                -- Set up the cruise route for AI vehicles, starting with closest ones
                                for i, vehData in ipairs(vehicleDistances) do
                                    job.sleep(1.5)
                                    
                                    local veh = vehData.vehicle
                                    if veh then
                                        local vehIndex = -1
                                        for j = 0, be:getObjectCount()-1 do
                                            if be:getObject(j) and be:getObject(j):getID() == vehData.id then
                                                vehIndex = j
                                                break
                                            end
                                        end
                                        
                                        if vehIndex >= 0 then
                                            local aiPath = getAiPath(rp.path, vehIndex)
                                            if aiPath and #aiPath > 0 then
                                                local pathStr = '{wpTargetList = '..serialize(aiPath)
                                                pathStr = pathStr..', noOfLaps = 1, aggression = 0.5, avoidCars = "on"}'
                                                veh:queueLuaCommand('ai.driveUsingPath('..pathStr..')')
                                                veh:queueLuaCommand('ai.setRacing(true)')
                                                veh:queueLuaCommand('ai.driveInLane("on")')
                                                
                                                print("Sending vehicle " .. vehData.id .. " (distance: " .. string.format("%.1f", vehData.distance) .. "m) on cruise route")
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                        
                        state.flags.cruiseStarted = true
                        state.flags.routeEndCheckRadius = 50
                        state.flags.routeEndPosition = state.flags.cruiseDestination
                    else
                        state.phase = "ending"
                    end
                elseif not state.flags.playerReachedDestination then
                    local playerVeh = be:getPlayerVehicle(0)
                    if playerVeh and state.flags.routeEndPosition then
                        local distance = (playerVeh:getPosition() - state.flags.routeEndPosition):length()
                        if state.phase ~= "ending" and distance < state.flags.routeEndCheckRadius + 100 then
                            state.phase = "ending"
                        end
                        if distance < state.flags.routeEndCheckRadius then
                            state.flags.playerReachedDestination = true
                            
                            local cruiseReputation = 5
                            if isHardcoreMode() then
                                cruiseReputation = cruiseReputation / 2
                            end
                            
                            local message = "Great cruise!\nYou completed the route with the group!\nBonus reputation: " .. cruiseReputation .. "%"
                            ui_message(message, 10, "info", "info")
                            
                            local cruiseVehicleId = getMeetVehicleInventoryId(state)
                            local _, cruiseMult, cruiseAdjusted = addPlayerMeetReputationForVehicle(cruiseReputation, cruiseVehicleId, "completed cruise")
                            if cruiseVehicleId then
                                awardCarRep(cruiseVehicleId, 1.5, "cruise complete")
                                appendMeetSceneEvent(cruiseVehicleId, {
                                    kind = "cruise",
                                    label = "Street cruise completed",
                                    playerRep = cruiseAdjusted,
                                    carRepDelta = 1.5,
                                    meetType = state.type
                                })
                            end
                            
                            meetRoute.clear()
                            career_saveSystem.saveCurrent()
                            
                            state.phase = "ending"
                            state.flags.dispersalStarted = false
                            clearMeetShowcasePois(state)
                        end
                    end
                end
            end
        end
    },
    CLUB = {
        name = "Car Club",
        description = "A club meet for owners with the right cars",
        unlockReputation = 30,
        expirationSeconds = DEFAULT_INVITE_EXPIRATION,
        missPenalty = 0,
        requiresVehicle = false,
        requiresActiveClub = true,
        baseReputationMultiplier = 1.2,
        showcaseDuration = 600,
        vehicleFilters = {
            whiteList = {
                ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe"}
            }
        },
        vehiclePoolRules = {
            tiers = {
                {populationMax = 5000},
                {populationMax = 10000}
            }
        },
        actions = {
            onArrival = function(reputation)
                return "Welcome to the club meet!\nYour scene reputation increased by " .. reputation .. "."
            end,
            onShowcaseEnd = function(state)
                state.phase = "ending"
                state.flags.dispersalStarted = false
                clearMeetShowcasePois(state)
                ui_message("Club meet is over, vehicles starting to leave!", 10, "info", "info")
            end,
            onLeave = function()
                return "Club meet is over. Thanks for coming!"
            end
        },
        onUpdate = nil
    },
    BAZAAR = {
        name = "Car Bazaar",
        description = "Bring a car, make deals, and try to leave with a sale",
        unlockReputation = 70,
        expirationSeconds = DEFAULT_INVITE_EXPIRATION,
        missPenalty = -2,
        requiresVehicle = true,
        requiresActiveClub = true,
        requiredClubId = "car_bazaar_club",
        baseReputationMultiplier = 1.0,
        showcaseDuration = 600,
        vehicleFilters = {
            whiteList = {
                ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe", "Truck"}
            }
        },
        vehiclePoolRules = {
            tiers = {
                {populationMax = 2500},
                {populationMax = 5000},
                {populationMax = 10000}
            }
        },
        actions = {
            onArrival = function(reputation)
                return "Welcome to the Car Bazaar!\nSell your brought vehicle before the meet ends."
            end,
            onShowcaseEnd = function(state)
                state.phase = "ending"
                state.flags.dispersalStarted = false
                clearMeetShowcasePois(state)
                if not state.flags.playerSoldSaleVehicle then
                    ui_message("Bazaar ended without a sale.", 10, "warning", "warning")
                else
                    ui_message("Bazaar is over, vehicles starting to leave!", 10, "info", "info")
                end
            end,
            onLeave = function()
                return "Bazaar complete. See you at the next one."
            end
        },
        onUpdate = function(state, currentTime)
            if state.phase ~= "showcase" then return end
            if not canPlayerSellAtMeet(state) then return end
            local inventoryId = state.flags.saleInventoryId
            if not inventoryId or state.flags.playerSoldSaleVehicle then return end
            local schedule = state.flags.bazaarOfferSchedule or {}
            local generated = state.flags.bazaarGuaranteedOffersGenerated or 0
            local nextOfferAt = schedule[generated + 1]
            if not nextOfferAt or currentTime < nextOfferAt then return end

            local offer = generateMeetSaleOffer(state, BAZAAR_OFFER_TTL)
            if offer then
                state.flags.bazaarGuaranteedOffersGenerated = generated + 1
                ui_message("A Bazaar buyer made an offer on your vehicle.", 6, "info", "info")
                if gameplay_rawPois and gameplay_rawPois.clear then
                    gameplay_rawPois.clear()
                end
                guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
            end
        end
    },
    ELITE = {
        name = "Elite Cars",
        description = "Invite-only high-end meet for rare and expensive builds",
        unlockReputation = 90,
        expirationSeconds = DEFAULT_INVITE_EXPIRATION,
        missPenalty = 0,
        requiresVehicle = true,
        requiresActiveClub = true,
        requiredClubId = "elite_cars_club",
        minVehicleValue = 200000,
        baseReputationMultiplier = 1.5,
        showcaseDuration = 600,
        vehicleFilters = {
            whiteList = {
                ["Body Style"] = {"Sedan", "Hatchback", "SUV", "Coupe"}
            }
        },
        vehiclePoolRules = {
            tiers = {
                {populationMax = 500, valueMin = 200000},
                {populationMax = 2500, valueMin = 200000},
                {populationMax = 5000, valueMin = 200000},
                {valueMin = 200000}
            }
        },
        actions = {
            onArrival = function(reputation)
                return "Welcome to the elite meet.\nYour scene reputation increased by " .. reputation .. "."
            end,
            onShowcaseEnd = function(state)
                state.phase = "ending"
                state.flags.dispersalStarted = false
                clearMeetShowcasePois(state)
                ui_message("Elite meet is over, vehicles starting to leave!", 10, "info", "info")
            end,
            onLeave = function()
                return "Elite meet complete."
            end
        },
        onUpdate = nil
    }
}

local function getMeetType(typeKey)
    return meetTypes[typeKey]
end

local function awardVehiclePopularityForMeet()
    if not career_modules_vehiclePopularity or not career_modules_vehiclePopularity.awardForCurrentVehicle then return nil end
    local meetType = getMeetType(meetState.type) or {}
    local locationName = rsvpData and rsvpData.location or (meetState.location and meetState.location.zone and meetState.location.zone.name) or "carMeet"
    return career_modules_vehiclePopularity.awardForCurrentVehicle({
        id = "carMeet:" .. tostring(locationName),
        type = meetState.type or "meet",
        localPopularityRewardMinPercent = meetType.localPopularityRewardMinPercent or 0.4,
        localPopularityRewardMaxPercent = meetType.localPopularityRewardMaxPercent or 1.0,
        localPopularityCapPercent = meetType.localPopularityCapPercent or 8
    })
end

-- === Lock-screen peek
-- Routes through the phone OS dispatcher so the player's Notifications toggle
-- (Settings -> Notifications -> Car Meet -> Invites) is always respected.
local function getPhoneLayout()
    if not ui_phone_layout and extensions and extensions.load then
        pcall(extensions.load, "ui_phone_layout")
    end
    return ui_phone_layout
end

local function firePhoneLockNotification(invite)
    if not invite then return end
    local layout = getPhoneLayout()
    if not (layout and layout.fireNotification) then return end
    local typeName = invite.typeName or invite.type or "Invite"
    local where = invite.location or invite.clubName or ""
    local message = where ~= "" and (typeName .. " - " .. where) or typeName
    layout.fireNotification("carMeet.invite", {
        title = "New Invite",
        message = message,
        kind = "invite",
        ttl = 8,
        meta = invite.clubName or "",
        source = "Car Meets",
        sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
    })
end

local function getCarMeetPopularityData()
    if not career_modules_vehiclePopularity and extensions and extensions.load then
        extensions.load("career_modules_vehiclePopularity")
    end
    if career_modules_vehiclePopularity and career_modules_vehiclePopularity.getPhoneSocialData then
        return career_modules_vehiclePopularity.getPhoneSocialData()
    end
    return {
        careerActive = career_career and career_career.isActive and career_career.isActive() or false,
        vehicles = {},
        carRepVehicles = {},
        historyVehicles = {},
        previousCars = {}
    }
end

local function requestVehicleHistory(inventoryId, archiveIndex)
    if not career_modules_vehiclePopularity and extensions and extensions.load then
        extensions.load("career_modules_vehiclePopularity")
    end
    if career_modules_vehiclePopularity and career_modules_vehiclePopularity.requestVehicleHistory then
        return career_modules_vehiclePopularity.requestVehicleHistory(inventoryId, archiveIndex)
    end
    return nil
end

local function requestCarMeetPopularityData()
    local data = getCarMeetPopularityData()
    if guihooks and guihooks.trigger then
        guihooks.trigger("onCarMeetPopularityData", data)
    end
    return data
end

local function updateMeetSaleOffers(state, currentTime)
    if not state or state.phase ~= "showcase" or state.type == "BAZAAR" then return end
    if not canPlayerSellAtMeet(state) then return end
    local inventoryId = state.flags and state.flags.saleInventoryId
    if not inventoryId or state.flags.playerSoldSaleVehicle then return end
    if currentTime < (state.flags.nextSellOfferCheckAt or 0) then return end

    state.flags.nextSellOfferCheckAt = currentTime + DEFAULT_SELL_OFFER_INTERVAL
    local listing = ensureMeetSaleState(state)
    local chance = getSellOfferChance(state.type) * getAskingPriceOfferChanceMultiplier(listing)
    if math.random() > math.min(0.95, chance) then return end

    local meetType = meetTypes[state.type]
    local remaining = meetType and state.arrivalTime and meetType.showcaseDuration and ((state.arrivalTime + meetType.showcaseDuration) - currentTime) or BAZAAR_OFFER_TTL
    local offer = generateMeetSaleOffer(state, math.max(60, remaining + 30))
    if offer then
        ui_message("Someone at the meet made an offer on your vehicle.", 6, "info", "info")
        if gameplay_rawPois and gameplay_rawPois.clear then
            gameplay_rawPois.clear()
        end
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    end
end

local function initializeMeetSaleOnArrival(state, currentTime)
    if not state or not state.flags or not state.flags.saleInventoryId or state.flags.saleInitialized then return end
    state.flags.saleInitialized = true
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId and playerVehicleId >= 0 then
        state.flags.saleVehicleId = playerVehicleId
    elseif state.flags.saleInventoryId and career_modules_inventory and career_modules_inventory.getVehicleIdFromInventoryId then
        local parkedVehId = career_modules_inventory.getVehicleIdFromInventoryId(state.flags.saleInventoryId)
        if parkedVehId and parkedVehId >= 0 then
            state.flags.saleVehicleId = parkedVehId
        end
    end
    ensureMeetSaleState(state)

    if state.type == "BAZAAR" then
        state.flags.bazaarOfferSchedule = {}
        local meetType = meetTypes[state.type] or {}
        local duration = meetType.showcaseDuration or 600
        for i = 1, state.flags.bazaarGuaranteedOffersTarget or 1 do
            table.insert(state.flags.bazaarOfferSchedule, currentTime + math.floor(duration * (i / ((state.flags.bazaarGuaranteedOffersTarget or 1) + 1))))
        end
    else
        state.flags.nextSellOfferCheckAt = currentTime + DEFAULT_SELL_OFFER_FIRST_CHECK
    end

    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
end

local function isPlayerWalkingMode()
    return gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() == true
end

local function isInventoryVehicleNearMeet(inventoryId, playerPos)
    if not inventoryId or not career_modules_inventory or not career_modules_inventory.getVehicleIdFromInventoryId then
        return false
    end
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not vehId then return false end
    local veh = getObjectByID(vehId)
    if not veh then return false end
    local vehPos = veh:getPosition()
    if meetState.playerSpot and meetState.playerSpot.pos then
        if (vehPos - vec3(meetState.playerSpot.pos)):length() <= PLAYER_VEHICLE_AT_MEET_DISTANCE then
            return true
        end
    end
    if playerPos and (vehPos - playerPos):length() <= PLAYER_VEHICLE_AT_MEET_DISTANCE then
        return true
    end
    return false
end

local function didPlayerBringVehicleToMeet()
    local playerPos = getPlayerReferencePosition()
    if not playerPos then return false end

    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId >= 0 and not isPlayerWalkingMode() then
        if meetState.flags then
            local inventoryId = resolveMeetSaleInventoryId()
            if inventoryId then
                meetState.flags.saleInventoryId = inventoryId
            end
        end
        return true
    end

    local saleInventoryId = meetState.flags and meetState.flags.saleInventoryId
    if saleInventoryId and isInventoryVehicleNearMeet(saleInventoryId, playerPos) then
        return true
    end

    if career_modules_inventory and career_modules_inventory.getLastVehicle then
        local lastId = career_modules_inventory.getLastVehicle()
        if lastId and isInventoryVehicleNearMeet(lastId, playerPos) then
            if meetState.flags then
                meetState.flags.saleInventoryId = lastId
            end
            return true
        end
    end

    return false
end

local function clearMeetSaleState(state)
    if not state or not state.flags then return end
    state.flags.saleInventoryId = nil
    state.flags.saleVehicleId = nil
    state.flags.saleListing = nil
    state.flags.saleOffers = nil
    state.flags.saleInitialized = true
    state.flags.bazaarOfferSchedule = nil
    state.flags.bazaarGuaranteedOffersTarget = nil
    state.flags.bazaarGuaranteedOffersGenerated = nil
    state.flags.nextSellOfferCheckAt = nil
end

local function isPlayerAtMeetArrivalPoint()
    if not meetState.playerSpot then return false end
    local playerPos = getPlayerReferencePosition()
    if not playerPos then return false end

    if (playerPos - vec3(meetState.playerSpot.pos)):length() < 10 then
        return true
    end

    if isPlayerWalkingMode() then
        for _, entry in ipairs(carMeetPurchaseVehicles or {}) do
            local veh = entry and entry.vehicleId and getObjectByID(entry.vehicleId)
            local pos = veh and veh:getPosition() or entry.pos
            if pos and (playerPos - vec3(pos)):length() <= WALKING_MEET_ARRIVAL_DISTANCE then
                return true
            end
        end
    end

    return false
end

local function hasActiveClubForMeetType(meetType)
    if not meetType or not meetType.requiresActiveClub then return true end
    if meetType.requiredClubId then
        return getActiveClubById(meetType.requiredClubId) ~= nil
    end
    return #getActiveClubs() > 0
end

local function getEligibleMeetTypeKeys()
    local keys = {}
    for key, meetType in pairs(meetTypes) do
        local unlockRep = meetType.unlockReputation or 0
        if playerMeetReputation >= unlockRep and hasActiveClubForMeetType(meetType) then
            table.insert(keys, key)
        end
    end
    if #keys == 0 then
        table.insert(keys, "SHOWCASE")
    end
    return keys
end

local function getMeetArray()
    if not ensureCarmeetSitesForCurrentLevel() then
        return {}
    end
    local meetArray = {}
    for name, data in pairs(carmeetLocations) do
        if data.parkingSpots and #data.parkingSpots > 1 then
            table.insert(meetArray, {name = name, data = data})
        end
    end
    return meetArray
end

local function buildInvite(selectedMeet, meetTypeKey)
    local meetType = meetTypes[meetTypeKey] or meetTypes.SHOWCASE
    local selectedClub = nil
    if meetType.requiresActiveClub then
        selectedClub = meetType.requiredClubId and selectActiveClub(meetType.requiredClubId, false) or selectActiveClub()
    end
    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/carmeets/" .. selectedMeet.name .. ".jpg"
    local now = os.time()
    local invite = {
        id = "carMeetInvite_" .. tostring(nextInviteId),
        generatedAt = now,
        expiresAt = now + (meetType.expirationSeconds or DEFAULT_INVITE_EXPIRATION),
        location = selectedMeet.name,
        type = meetTypeKey,
        typeName = meetType.name,
        description = meetType.description,
        preview = preview,
        missPenalty = meetType.missPenalty or 0,
        requiresVehicle = meetType.requiresVehicle == true,
        minVehicleValue = meetType.minVehicleValue,
        attendance = attendanceLevels.MEDIUM
    }
    if selectedClub then
        invite.clubId = selectedClub.id
        invite.clubName = selectedClub.name
    end
    nextInviteId = nextInviteId + 1
    return invite
end

local function removePendingInvite(inviteId)
    if not inviteId then return nil end
    for i, invite in ipairs(pendingInvites) do
        if invite.id == inviteId then
            return table.remove(pendingInvites, i)
        end
    end
    return nil
end

local function applyInvitePenalty(invite, reason, opts)
    opts = opts or {}
    if invite and invite.clubId then
        recordClubMeetResult(invite.clubId, false, reason or "missed club invite")
    end
    -- Scene reputation only drops when missing an accepted Car Bazaar RSVP.
    if not opts.sceneRep then return end
    if not invite or invite.type ~= "BAZAAR" then return end
    local penalty = tonumber(invite.missPenalty)
    if not penalty or penalty == 0 then
        local meetType = meetTypes.BAZAAR
        penalty = meetType and tonumber(meetType.missPenalty) or 0
    end
    if penalty == 0 then return end
    addPlayerMeetReputation(penalty, reason or "missed bazaar invite")
    ui_message("Car meet reputation changed by " .. tostring(penalty) .. ".", 8, "warning", "warning")
end

local function expirePendingInvites()
    local now = os.time()
    local expiredAny = false
    for i = #pendingInvites, 1, -1 do
        local invite = pendingInvites[i]
        if invite.expiresAt and now >= invite.expiresAt then
            table.remove(pendingInvites, i)
            applyInvitePenalty(invite, "expired invite")
            expiredAny = true
        end
    end
    return expiredAny
end

local getClubUiData

local function buildMeetSaleListingPayload(listing)
    if not listing then return nil end
    local niceName = listing.niceName
    if core_locales and core_locales.translateWithOrWithoutContext and niceName ~= nil then
        local translated = core_locales.translateWithOrWithoutContext(niceName)
        if type(translated) == "string" and translated ~= "" then
            niceName = translated
        end
    end
    return {
        id = listing.id,
        niceName = niceName,
        value = listing.value,
        marketValue = listing.marketValue,
        minAskingPrice = math.floor(math.max(50, (tonumber(listing.marketValue) or 0) * 0.5)),
        maxAskingPrice = math.floor(math.max(50, (tonumber(listing.marketValue) or 0) * 2.0)),
        thumbnail = listing.thumbnail
    }
end

local function buildMeetSaleOverviewPayload()
    if not meetState.active or not meetState.flags or not meetState.flags.saleInventoryId then
        return nil
    end
    if meetState.phase ~= "showcase" or meetState.flags.playerSoldSaleVehicle == true then
        return nil
    end

    local listing
    if meetState.flags.playerBroughtVehicle or meetState.flags.saleInitialized then
        listing = meetState.flags.saleListing or ensureMeetSaleState(meetState)
    else
        local inventoryId = meetState.flags.saleInventoryId
        local vehicle = getInventoryVehicle(inventoryId) or {}
        local marketValue = getInventoryVehicleValue(inventoryId)
        listing = {
            id = inventoryId,
            inventoryId = inventoryId,
            niceName = getInventoryVehicleDisplayName(vehicle, "Your vehicle"),
            value = marketValue,
            marketValue = marketValue,
            thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil
        }
    end
    if not listing then return nil end

    return {
        type = meetState.type,
        inventoryId = meetState.flags.saleInventoryId,
        sold = false,
        guaranteed = meetState.type == "BAZAAR",
        guaranteedTarget = meetState.flags.bazaarGuaranteedOffersTarget or 0,
        guaranteedGenerated = meetState.flags.bazaarGuaranteedOffersGenerated or 0,
        offers = meetState.flags.saleOffers or {},
        canReceiveOffers = canPlayerSellAtMeet(meetState),
        needsVehicleAtMeet = meetState.flags.playerBroughtVehicle ~= true,
        listing = buildMeetSaleListingPayload(listing)
    }
end

local function reconcileActiveMeetInvite()
    if rsvpData or not meetState.active then return end
    local locationName = meetState.location and meetState.location.zone and meetState.location.zone.name
    for i, invite in ipairs(pendingInvites) do
        if invite.location == locationName and invite.type == meetState.type then
            rsvpData = table.remove(pendingInvites, i)
            break
        end
    end
end

getCarMeetOverview = function()
    reconcileActiveMeetInvite()
    local showActiveMeet = meetState.active
    local salePayload = showActiveMeet and buildMeetSaleOverviewPayload() or nil
    return {
        reputation = math.floor(playerMeetReputation + 0.5),
        maxReputation = MAX_REPUTATION,
        pendingInviteCap = getPendingInviteCap(),
        invites = pendingInvites,
        activeInvite = showActiveMeet and rsvpData or nil,
        currentMeet = showActiveMeet and {
            type = meetState.type,
            phase = meetState.phase,
            location = rsvpData and rsvpData.location or (meetState.location and meetState.location.zone and meetState.location.zone.name),
            typeName = rsvpData and rsvpData.typeName or (meetTypes[meetState.type] and meetTypes[meetState.type].name),
            clubId = meetState.flags and meetState.flags.clubId,
            clubName = meetState.flags and meetState.flags.clubName,
            startTime = meetState.startTime,
            arrivalTime = meetState.arrivalTime,
            duration = meetTypes[meetState.type] and meetTypes[meetState.type].showcaseDuration or 600,
            arrived = meetState.phase ~= "waiting"
        } or nil,
        meetPurchaseVehicles = carMeetPurchaseVehicles,
        sale = salePayload and meetState.type ~= "BAZAAR" and salePayload or nil,
        bazaar = salePayload and meetState.type == "BAZAAR" and salePayload or nil,
        clubs = getClubUiData()
    }
end

getClubUiData = function()
    local money = getPlayerMoney()
    local availableClubs = {}
    local joinedClubList = {}

    for _, club in ipairs(loadClubDefinitions()) do
        local joined = isClubJoined(club.id)
        local membership = joined and ensureClubMembership(club.id) or nil
        local active = isClubActive(club)
        local hasVehicle = playerOwnsClubVehicle(club)
        local requiredRep = tonumber(club.requiredRep) or 0
        local joinFee = tonumber(club.joinFee) or 0
        local obligationEvents = membership and tonumber(membership.obligationEvents) or 0
        local obligationAttended = membership and tonumber(membership.obligationAttended) or 0
        local obligationWindowSize = membership and tonumber(membership.obligationWindowSize) or CLUB_OBLIGATION_WINDOW_SIZE
        local requiredAttendance = membership and tonumber(membership.requiredAttendance) or CLUB_OBLIGATION_REQUIRED_ATTENDANCE
        local canJoin = not joined and playerMeetReputation >= requiredRep and hasVehicle and money >= joinFee
        local disableReason = nil
        if joined then
            disableReason = active and "Joined" or "Inactive: missing qualifying vehicle"
        elseif playerMeetReputation < requiredRep then
            disableReason = "Requires " .. tostring(requiredRep) .. " rep"
        elseif not hasVehicle then
            disableReason = "Requires qualifying vehicle"
        elseif money < joinFee then
            disableReason = "Requires $" .. tostring(joinFee)
        end

        local entry = {
            id = club.id,
            name = club.name,
            type = club.type,
            requiredRep = requiredRep,
            joinFee = joinFee,
            joined = joined,
            active = active,
            hasVehicle = hasVehicle,
            canJoin = canJoin,
            disableReason = disableReason,
            requirementsText = clubRequirementText(club.requirements),
            standing = membership and math.floor((tonumber(membership.standing) or CLUB_STANDING_MAX) + 0.5) or nil,
            paidJoinFee = membership and tonumber(membership.paidJoinFee) or nil,
            obligationEvents = obligationEvents,
            obligationAttended = obligationAttended,
            obligationWindowSize = obligationWindowSize,
            requiredAttendance = requiredAttendance,
            obligationText = tostring(obligationAttended) .. "/" .. tostring(requiredAttendance) .. " attended in current " .. tostring(obligationWindowSize) .. "-event window"
        }

        if joined then
            table.insert(joinedClubList, entry)
        elseif hasVehicle or club.type == "special" then
            table.insert(availableClubs, entry)
        end
    end

    return {
        reputation = math.floor(playerMeetReputation + 0.5),
        money = money,
        availableClubs = availableClubs,
        joinedClubs = joinedClubList
    }
end

local function joinClub(clubId)
    clubId = tostring(clubId or "")
    for _, club in ipairs(loadClubDefinitions()) do
        if club.id == clubId then
            if isClubJoined(clubId) then
                return getClubUiData()
            end
            local requiredRep = tonumber(club.requiredRep) or 0
            local joinFee = tonumber(club.joinFee) or 0
            if playerMeetReputation < requiredRep then
                ui_message("You need more car meet rep to join this club.", 5, "warning", "warning")
                return getClubUiData()
            end
            if not playerOwnsClubVehicle(club) then
                ui_message("You need a qualifying vehicle to join this club.", 5, "warning", "warning")
                return getClubUiData()
            end
            if getPlayerMoney() < joinFee then
                ui_message("You cannot afford this club's joining fee.", 5, "warning", "warning")
                return getClubUiData()
            end
            if joinFee > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
                career_modules_playerAttributes.addAttributes({money = -joinFee}, {tags = {"carMeet", "clubJoin"}, label = "Joined car club: " .. (club.name or clubId)})
            end
            joinedClubs[clubId] = {
                joinedAt = os.time(),
                paidJoinFee = joinFee,
                standing = CLUB_STANDING_MAX,
                obligationEvents = 0,
                obligationAttended = 0,
                obligationWindowSize = CLUB_OBLIGATION_WINDOW_SIZE,
                requiredAttendance = CLUB_OBLIGATION_REQUIRED_ATTENDANCE
            }
            markCarmeetsDirty()
            ui_message("Joined " .. (club.name or "car club") .. ".", 5, "info", "info")
            career_saveSystem.saveCurrent()
            guihooks.trigger('onCarMeetClubs', getClubUiData())
            guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
            return getClubUiData()
        end
    end
    ui_message("Club not found.", 5, "warning", "warning")
    return getClubUiData()
end

local function leaveClub(clubId)
    clubId = tostring(clubId or "")
    if joinedClubs[clubId] then
        local clubName = "car club"
        for _, club in ipairs(loadClubDefinitions()) do
            if tostring(club.id) == clubId then
                clubName = club.name or clubName
                break
            end
        end
        joinedClubs[clubId] = nil
        markCarmeetsDirty()
        ui_message("Left " .. clubName .. ".", 5, "info", "info")
        career_saveSystem.saveCurrent()
        guihooks.trigger('onCarMeetClubs', getClubUiData())
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
        return getClubUiData()
    end
    ui_message("You are not in that car club.", 5, "warning", "warning")
    return getClubUiData()
end

local function getBuildSignature(inventoryId)
    local vehicle = getInventoryVehicle(inventoryId)
    if not vehicle then return nil end
    local signatureData = {
        model = vehicle.model,
        config = {}
    }
    if vehicle.config then
        signatureData.config.partConfigFilename = vehicle.config.partConfigFilename
        signatureData.config.parts = vehicle.config.parts or vehicle.config.partsTree
        signatureData.config.vars = vehicle.config.vars
        signatureData.config.paints = vehicle.config.paints or vehicle.config.paintsData
        signatureData.config.licenseName = vehicle.config.licenseName
    end
    return sortedStableSerialize(signatureData)
end

local function calculateAttendanceReputation()
    local inventoryId = getCurrentInventoryId()
    if not inventoryId then
        return 0, "Attending without a vehicle gives no attendance rep.", nil
    end

    local signature = getBuildSignature(inventoryId)
    if not signature then
        return 0, "Could not read current vehicle build data.", inventoryId
    end

    local historyKey = tostring(inventoryId)
    local previous = attendanceHistory[historyKey]
    if previous and previous.signature == signature then
        return 0, "This vehicle already earned meet rep with the same build.", inventoryId
    end

    local value = getInventoryVehicleValue(inventoryId)
    local valueBonus = 0
    if value > 30000 then
        valueBonus = math.min(5, math.max(0, inverseLerp(30000, 200000, value) * 5))
    end
    local changedBonus = previous and 2 or 0
    local rep = 1 + valueBonus + changedBonus
    if isHardcoreMode() then
        rep = rep / 2
    end
    rep = math.max(1, rep)

    attendanceHistory[historyKey] = {
        signature = signature,
        lastRewardedAt = os.time(),
        lastReward = rep,
        value = value
    }

    return rep, string.format("Attendance rep: +%.1f", rep), inventoryId
end

local function cleanupPreviousMeet()
    local previousFlags = meetState.flags or {}

    for _, vehId in ipairs(spawnedMeetVehicles) do
        gameplay_traffic.removeTraffic(vehId)
        local veh = getObjectByID(vehId)
        if veh then
            veh:delete()
        end
    end
    spawnedMeetVehicles = {}
    if career_modules_vehicleShopping and career_modules_vehicleShopping.removeCarMeetVehicles then
        career_modules_vehicleShopping.removeCarMeetVehicles()
    end
    carMeetPurchaseVehicles = {}
    pendingVehicles = {}
    meetRoute.clear()
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
    
    restoreTrafficAmount()
    
    meetState.active = false
    meetState.type = nil
    meetState.location = nil
    meetState.playerSpot = nil
    meetState.startTime = 0
    meetState.arrivalTime = 0
    meetState.flags = {}
    meetState.phase = "waiting"
end

local function getCarMeetVehicles(meetType, club)
    local vehicles = {}
    local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
    
    local filters = meetType and meetType.vehicleFilters or meetTypes.SHOWCASE.vehicleFilters
    local poolRuleTiers = getMeetVehiclePoolRules(meetType)
    local vehiclesForInfos = eligibleVehicles

    if club then
        vehiclesForInfos = {}
        for _, vehicleInfo in ipairs(eligibleVehicles or {}) do
            if vehicleInfoMatchesClub(vehicleInfo, club) then
                table.insert(vehiclesForInfos, vehicleInfo)
            end
        end
        if #vehiclesForInfos == 0 then
            print("No eligible car meet vehicles found for club " .. tostring(club.name or club.id) .. ".")
            return vehicles
        end
        print("Eligible car meet vehicles for " .. tostring(club.name or club.id) .. ": " .. tostring(#vehiclesForInfos))
    end

    if poolRuleTiers then
        local matchedInfos = {}
        local matchedRules = nil
        for _, rules in ipairs(poolRuleTiers) do
            matchedInfos = filterVehicleInfosForPoolRules(vehiclesForInfos, rules)
            if #matchedInfos > 0 then
                matchedRules = rules
                break
            end
        end
        if #matchedInfos > 0 then
            vehiclesForInfos = matchedInfos
            print("Applied car meet vehicle pool rules for " .. tostring(meetType and meetType.name or "meet")
                .. ": " .. tostring(#vehiclesForInfos) .. " eligible vehicles"
                .. " (populationMax=" .. tostring(matchedRules and matchedRules.populationMax or "any")
                .. ", valueMin=" .. tostring(matchedRules and matchedRules.valueMin or "any") .. ")")
        else
            print("No vehicles matched car meet pool rules for " .. tostring(meetType and meetType.name or "meet") .. ". Falling back to identity-filtered pool.")
        end
    end
    
    local vehicleInfos = util_configListGenerator.getRandomVehicleInfos(
        {filter = filters},
        (club or poolRuleTiers) and 800 or 100,
        vehiclesForInfos,
        "Population"
    )

    local filteredInfos = vehicleInfos
    if club then
        filteredInfos = {}
        for _, vehicleInfo in ipairs(vehicleInfos) do
            if vehicleInfoMatchesClub(vehicleInfo, club) then
                table.insert(filteredInfos, vehicleInfo)
            end
        end
        if #filteredInfos == 0 then
            print("No sampled car meet vehicles matched club " .. tostring(club.name or club.id) .. " after meet filters.")
            return vehicles
        else
            print("Filtered car meet vehicles for " .. tostring(club.name or club.id) .. ": " .. tostring(#filteredInfos) .. " of " .. tostring(#vehicleInfos))
        end
    end

    for _, vehicleInfo in ipairs(filteredInfos) do
        local pcPath = '/vehicles/' .. vehicleInfo.model_key .. '/configurations/' .. vehicleInfo.key .. '.pc'
        table.insert(vehicles, {
            model = vehicleInfo.model_key,
            config = pcPath,
            info = vehicleInfo
        })
    end
    
    return vehicles
end

local function getRandomVehicle(meetType, club)
    if #carMeetVehicles == 0 then 
        carMeetVehicles = getCarMeetVehicles(meetType, club)
        if #carMeetVehicles == 0 then
            print("No carmeet vehicles found for type: " .. (meetType and meetType.name or "unknown"))
            return nil
        end
    end
    
    local availableVehicles = {}
    for _, vehicle in ipairs(carMeetVehicles) do
        if not usedConfigs[vehicle.config] then
            table.insert(availableVehicles, vehicle)
        end
    end
    
    if #availableVehicles == 0 then
        print("No unused vehicle configs available, allowing repeats for this meet")
        usedConfigs = {}
        carMeetVehicles = getCarMeetVehicles(meetType, club)
        for _, vehicle in ipairs(carMeetVehicles) do
            table.insert(availableVehicles, vehicle)
        end
        if #availableVehicles == 0 then
            return nil
        end
    end
    
    local vehicle = availableVehicles[math.random(#availableVehicles)]
    usedConfigs[vehicle.config] = true
    
    print("Selected vehicle: " .. vehicle.model .. " with config: " .. vehicle.config)
    return vehicle
end

local function flushMeetSpawnPoisRefresh()
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
end

local function spawnVehicleOptimized(spot, meetType, forceVisible, club, deferPoiRefresh)
    local vehicleSelection = getRandomVehicle(meetType, club)
    if not vehicleSelection then return nil end
    
    local options = {
        config = vehicleSelection.config,
        autoEnterVehicle = false,
        autoFlip = true,
        pos = vec3(spot.pos),
        rot = quat(spot.rot)
    }

    pcall(function()
        applyRandomPaintToSpawnOptions(options, vehicleSelection.model, vehicleSelection.config)
    end)
    
    local vehicle = core_vehicles.spawnNewVehicle(vehicleSelection.model, options)
    
    if vehicle then
        local vehId = vehicle:getID()
        gameplay_traffic.insertTraffic(vehId, true)
        pcall(function()
            applyRandomPaintToSpawnedVehicle(vehId, options.carMeetRandomPaintNames, vehicleSelection.model)
        end)
        vehicle.playerUsable = false
        vehicle:queueLuaCommand('electrics.setLightsState(1)')
        vehicle:queueLuaCommand('electrics.setIgnitionLevel(1)')
        
        if not forceVisible then
            vehicle:setHidden(true)
        end
        
        table.insert(spawnedMeetVehicles, vehId)
        if career_modules_vehicleShopping and career_modules_vehicleShopping.registerCarMeetVehicle then
            local shopInfo = buildCarMeetVehicleShopInfo(vehicleSelection, spot, meetState.type)
            if type(options.carMeetRandomPaintNames) == "table" then
                shopInfo.paintNames = deepcopy(options.carMeetRandomPaintNames)
            end
            local shopId = career_modules_vehicleShopping.registerCarMeetVehicle(shopInfo)
            if shopId then
                table.insert(carMeetPurchaseVehicles, {
                    shopId = shopId,
                    vehicleId = vehId,
                    modelKey = vehicleSelection.model,
                    paintNames = shopInfo.paintNames,
                    name = shopInfo.niceName,
                    sellerName = shopInfo.sellerName,
                    meetType = meetState.type,
                    pos = vec3(spot.pos),
                    markerRadius = spot.scl and spot.scl:length() / 2 + 2 or 5
                })
                if not deferPoiRefresh then
                    flushMeetSpawnPoisRefresh()
                end
            end
        end
        
        return {
            id = vehId,
            pos = vec3(spot.pos),
            visible = forceVisible or false,
            hasCollision = forceVisible or false
        }
    end
    
    return nil
end

local function checkVehicleVisible(playerPos, vehiclePos)
    local startPos = playerPos + vec3(0, 0, 1.5)
    local endPos = vehiclePos + vec3(0, 0, 1)
    local direction = endPos - startPos
    local distance = direction:length()
    
    direction:normalize()
    local hitDistance = castRayStatic(startPos, direction, distance)
    return hitDistance >= distance * 0.90
end

local function shouldRevealMeetVehicle(playerPos, vehiclePos)
    if (vehiclePos - playerPos):length() > VEHICLE_SPAWN_DISTANCE then
        return false
    end
    return checkVehicleVisible(playerPos, vehiclePos)
end

local function updateVehicleVisibility()
    if not meetState.active then return end
    
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return end
    local playerPos = playerVeh:getPosition()
    local unhideBudget = PRESPAWN_MEET_VEHICLES_ON_ACCEPT and PRESPAWN_UNHIDE_PER_UPDATE or nil
    
    for i = #spawnedMeetVehicles, 1, -1 do
        local vehId = spawnedMeetVehicles[i]
        local veh = getObjectByID(vehId)
        
        if veh then
            local vehiclePos = veh:getPosition()
            local shouldBeVisible = PRESPAWN_MEET_VEHICLES_ON_ACCEPT
                and shouldRevealMeetVehicle(playerPos, vehiclePos)
                or checkVehicleVisible(playerPos, vehiclePos)
            
            if shouldBeVisible and veh:isHidden() then
                if unhideBudget == nil or unhideBudget > 0 then
                    veh:setHidden(false)
                    if unhideBudget then unhideBudget = unhideBudget - 1 end
                end
            elseif not shouldBeVisible and not veh:isHidden() then
                veh:setHidden(true)
            end
        else
            table.remove(spawnedMeetVehicles, i)
        end
    end
    
    if not PRESPAWN_MEET_VEHICLES_ON_ACCEPT then
        for spotData in pairs(pendingVehicles) do
            local distance = (spotData.pos - playerPos):length()
            if distance <= VEHICLE_SPAWN_DISTANCE then
                local shouldBeVisible = checkVehicleVisible(playerPos, spotData.pos)
                local vehicleData = spawnVehicleOptimized(spotData, spotData.meetType, shouldBeVisible, spotData.club)
                pendingVehicles[spotData] = nil
            end
        end
    end
end

local function onExtensionLoaded()
    print("Carmeets module initialized")
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
end

getCarMeetLocations = function()
    local locations = {}
    
    local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('carmeet')
    if not sitePath then
        return locations
    end
    
    local siteData = gameplay_sites_sitesManager.loadSites(sitePath)
    if not siteData then
        return locations
    end

    for _, zone in ipairs(siteData.zones.sorted) do
        local meetName = zone.name
        locations[meetName] = {
            zone = zone,
            parkingSpots = {},
            position = vec3(zone.top.pos),
            tags = zone.customFields.sortedTags
        }

        for _, spot in ipairs(siteData.parkingSpots.sorted) do
            for _, tag in ipairs(spot.customFields.sortedTags) do
                if tag == meetName then
                    table.insert(locations[meetName].parkingSpots, spot)
                end
            end
        end
    end

    carmeetLocations = locations

    return locations
end

ensureCarmeetSitesForCurrentLevel = function()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then
        carmeetSitesLevelId = nil
        carmeetSitesAvailable = false
        carmeetLocations = {}
        return false
    end
    if carmeetSitesLevelId == levelId then
        return carmeetSitesAvailable
    end

    carmeetSitesLevelId = levelId
    carmeetLocations = getCarMeetLocations()
    carmeetSitesAvailable = next(carmeetLocations) ~= nil
    return carmeetSitesAvailable
end

local function clearCarmeetStateForUnavailableMap()
    if rsvpData then
        rsvpData = nil
        meetRoute.clear()
    end
    if meetState.active then
        cleanupPreviousMeet()
    end
end

local function onWorldReadyState(state)
    if state == 2 and careerActive then
        carmeetSitesLevelId = nil
        ensureCarmeetSitesForCurrentLevel()
        local _, activeSavePath = career_saveSystem.getCurrentProfile()
        if activeSavePath then
            persist.load(activeSavePath)
        end
        if meetState.active then
            cleanupPreviousMeet()
        end
        if not carmeetSitesAvailable then
            clearCarmeetStateForUnavailableMap()
        elseif rsvpData and rsvpData.location and not carmeetLocations[rsvpData.location] then
            clearCarmeetStateForUnavailableMap()
        elseif rsvpData and rsvpData.location and not meetState.active then
            startCarMeet(rsvpData.location, rsvpData.type, rsvpData.attendance, rsvpData.clubId)
        end
    end
end

startCarMeet = function(meetName, meetTypeKey, attendanceLevel, clubId)
    usedConfigs = {}
    
    cleanupPreviousMeet()
    
    if not ensureCarmeetSitesForCurrentLevel() then
        return
    end
    local meet = carmeetLocations[meetName]
    if not meet then
        print("Car meet location not found: " .. meetName)
        return
    end
    
    local meetType = getMeetType(meetTypeKey)
    if not meetType then
        print("Meet type not found: " .. meetTypeKey)
        return
    end
    
    meetState.active = true
    meetState.type = meetTypeKey
    meetState.location = meet
    meetState.startTime = os.time()
    meetState.arrivalTime = 0
    meetState.phase = "waiting"
    meetState.flags = {}
    local selectedClub = nil
    if meetType.requiresActiveClub then
        local requiredClubId = meetType.requiredClubId or clubId
        selectedClub = requiredClubId and selectActiveClub(requiredClubId, false) or selectActiveClub()
    end
    if meetType.requiresActiveClub and not selectedClub then
        print("Car meet type requires an active club, but none was found: " .. tostring(meetTypeKey))
        ui_message("This invite requires an active car club.", 6, "warning", "warning")
        meetState.active = false
        meetState.type = nil
        meetState.location = nil
        meetState.flags = {}
        return
    end
    if selectedClub then
        meetState.flags.clubId = selectedClub.id
        meetState.flags.clubName = selectedClub.name
    end
    local saleInventoryId = resolveMeetSaleInventoryId()
    if saleInventoryId then
        meetState.flags.saleInventoryId = saleInventoryId
        meetState.flags.playerSoldSaleVehicle = false
        meetState.flags.saleInitialized = false
    end
    if meetTypeKey == "BAZAAR" then
        local inventoryId = saleInventoryId
        meetState.flags.bazaarInventoryId = inventoryId
        meetState.flags.playerSoldBazaarVehicle = false
        meetState.flags.bazaarGuaranteedOffersTarget = math.random(1, 2)
        meetState.flags.bazaarGuaranteedOffersGenerated = 0
        meetState.flags.bazaarOfferSchedule = {}
    end
    
    local maxSpots = #meet.parkingSpots - 1
    local spotCount
    if attendanceLevel == 1 then
        spotCount = 2
    elseif attendanceLevel == 2 then
        spotCount = math.ceil(maxSpots / 2)
    elseif attendanceLevel == 3 then
        spotCount = maxSpots
    end
    
    spotCount = math.min(spotCount, maxSpots)
    
    carMeetVehicles = getCarMeetVehicles(meetType, selectedClub)
    
    local spawnedVehicles = {}
    
    local availableSpots = deepcopy(meet.parkingSpots)

    local playerVehicleId = be:getPlayerVehicleID(0)
    meetState.playerSpot = playerVehicleId and playerVehicleId >= 0 and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(playerVehicleId, availableSpots) or availableSpots[1]
    for i, spot in ipairs(availableSpots) do
        if spot == meetState.playerSpot then
            table.remove(availableSpots, i)
            break
        end
    end

    local options = {
        color = {1, 0.4, 0},
        step = 4,
        renderDecals = true
    }
    meetRoute.set(meetState.playerSpot.pos, options)
    
    local playerVeh = be:getPlayerVehicle(0)
    local playerPos = playerVeh and playerVeh:getPosition() or vec3(meet.position)
    
    core_jobsystem.create(function(job)
        local deferPoiRefresh = PRESPAWN_MEET_VEHICLES_ON_ACCEPT
        for i = 1, spotCount do
            local randomIndex = math.random(#availableSpots)
            local spot = availableSpots[randomIndex]
            table.remove(availableSpots, randomIndex)
            
            if PRESPAWN_MEET_VEHICLES_ON_ACCEPT then
                local vehicleData = spawnVehicleOptimized(spot, meetType, false, selectedClub, true)
                if vehicleData then
                    table.insert(spawnedVehicles, vehicleData)
                end
            else
                local distance = (vec3(spot.pos) - playerPos):length()
                if distance <= VEHICLE_SPAWN_DISTANCE then
                    local forceVisible = checkVehicleVisible(playerPos, vec3(spot.pos))
                    local vehicleData = spawnVehicleOptimized(spot, meetType, forceVisible, selectedClub)
                    if vehicleData then
                        table.insert(spawnedVehicles, vehicleData)
                    end
                else
                    local spotData = {
                        pos = vec3(spot.pos),
                        rot = quat(spot.rot),
                        meetType = meetType,
                        club = selectedClub
                    }
                    pendingVehicles[spotData] = true
                end
            end
            job.sleep(PRESPAWN_MEET_VEHICLES_ON_ACCEPT and PRESPAWN_SPAWN_STAGGER or 0.1)
        end
        if deferPoiRefresh then
            flushMeetSpawnPoisRefresh()
        end
    end)
    
    return
end

local function shouldGenerateNewMeet()
    if meetState.active then return false end
    local currentTime = os.time()
    return (currentTime - lastGenerationTime) >= generationInterval and #pendingInvites < getPendingInviteCap()
end

local function checkAvailableMeets()
    local expiredAny = expirePendingInvites()

    if shouldGenerateNewMeet() then
        local meetArray = getMeetArray()
        if #meetArray > 0 then
            local selectedMeet = meetArray[math.random(#meetArray)]
            local typeKeys = getEligibleMeetTypeKeys()
            local selectedTypeKey = typeKeys[math.random(#typeKeys)]

            local newInvite = buildInvite(selectedMeet, selectedTypeKey)
            table.insert(pendingInvites, newInvite)
            firePhoneLockNotification(newInvite)
            lastGenerationTime = os.time()
            generationInterval = DEFAULT_INVITE_GENERATION_INTERVAL
            career_saveSystem.saveCurrent()
            expiredAny = false
        end
    end

    if expiredAny then
        career_saveSystem.saveCurrent()
    end

    return getCarMeetOverview()
end

local function generateInviteNow()
    expirePendingInvites()

    if #pendingInvites >= getPendingInviteCap() then
        ui_message("Car meet invite list is full.", 5, "info", "info")
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
        return getCarMeetOverview()
    end

    local meetArray = getMeetArray()
    if #meetArray == 0 then
        ui_message("No car meet locations available on this map.", 5, "warning", "warning")
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
        return getCarMeetOverview()
    end

    local selectedMeet = meetArray[math.random(#meetArray)]
    local typeKeys = getEligibleMeetTypeKeys()
    local selectedTypeKey = typeKeys[math.random(#typeKeys)]
    local invite = buildInvite(selectedMeet, selectedTypeKey)

    table.insert(pendingInvites, invite)
    firePhoneLockNotification(invite)
    lastGenerationTime = os.time()
    career_saveSystem.saveCurrent()
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    ui_message("Generated car meet invite: " .. (invite.typeName or invite.type), 5, "info", "info")

    return getCarMeetOverview()
end

local function debugAdjustReputation(amount)
    addPlayerMeetReputation(tonumber(amount) or 0, "debug adjustment")
    career_saveSystem.saveCurrent()
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    return getCarMeetOverview()
end

local function clearPendingInvites()
    pendingInvites = {}
    career_saveSystem.saveCurrent()
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    ui_message("Cleared pending invites.", 4, "info", "info")
    return getCarMeetOverview()
end

local function debugAccelerateInvite()
    generationInterval = DEFAULT_INVITE_GENERATION_INTERVAL
    lastGenerationTime = os.time() - (generationInterval - 10)
    career_saveSystem.saveCurrent()
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    ui_message("Next invite in ~10 seconds.", 5, "info", "info")
    return getCarMeetOverview()
end

local function generateInviteOfType(typeKey)
    expirePendingInvites()
    typeKey = tostring(typeKey or "SHOWCASE")
    local meetType = meetTypes[typeKey]
    if not meetType then
        ui_message("Unknown car meet type: " .. typeKey, 5, "warning", "warning")
        return getCarMeetOverview()
    end
    if #pendingInvites >= getPendingInviteCap() then
        ui_message("Car meet invite list is full.", 5, "info", "info")
        return getCarMeetOverview()
    end
    if playerMeetReputation < (meetType.unlockReputation or 0) then
        ui_message("Not enough rep for " .. meetType.name .. ".", 5, "warning", "warning")
        return getCarMeetOverview()
    end
    if not hasActiveClubForMeetType(meetType) then
        ui_message("No active club for " .. meetType.name .. ".", 5, "warning", "warning")
        return getCarMeetOverview()
    end

    local meetArray = getMeetArray()
    if #meetArray == 0 then
        ui_message("No car meet locations available on this map.", 5, "warning", "warning")
        return getCarMeetOverview()
    end
    local invite = buildInvite(meetArray[math.random(#meetArray)], typeKey)
    table.insert(pendingInvites, invite)
    firePhoneLockNotification(invite)
    lastGenerationTime = os.time()
    career_saveSystem.saveCurrent()
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    ui_message("Generated " .. (invite.typeName or invite.type) .. " invite.", 5, "info", "info")
    return getCarMeetOverview()
end

local function dumpDebugState()
    print("Car meet debug state: " .. serialize({
        reputation = playerMeetReputation,
        pendingInvites = pendingInvites,
        rsvpData = rsvpData,
        joinedClubs = joinedClubs,
        attendanceHistory = attendanceHistory,
        meetState = {
            active = meetState.active,
            type = meetState.type,
            phase = meetState.phase,
            startTime = meetState.startTime,
            arrivalTime = meetState.arrivalTime,
            flags = meetState.flags
        }
    }))
    ui_message("Car meet state dumped to log.", 4, "info", "info")
    return getCarMeetOverview()
end

local function validateInviteAcceptance(invite)
    if not invite then return false, "Invite not found." end
    local meetType = meetTypes[invite.type]
    if not meetType then return false, "Meet type not found." end
    if meetType.requiresActiveClub then
        local requiredClubId = meetType.requiredClubId or invite.clubId
        local selectedClub = requiredClubId and selectActiveClub(requiredClubId, false) or selectActiveClub()
        if not selectedClub then
            return false, "This invite requires an active car club."
        end
    end
    local inventoryId = getCurrentInventoryId()
    if meetType.requiresVehicle and not inventoryId then
        return false, "This meet requires you to bring a vehicle."
    end
    if meetType.minVehicleValue then
        local vehicleValue = getInventoryVehicleValue(inventoryId)
        if vehicleValue < meetType.minVehicleValue then
            return false, "This meet requires a vehicle worth at least $" .. tostring(meetType.minVehicleValue) .. "."
        end
    end
    return true
end

local function rsvpToMeet(inviteId, level)
    if meetState.active then
        ui_message("You already have an active car meet invite.", 5, "info", "info")
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
        return false
    end
    local invite = removePendingInvite(inviteId)
    if not invite then
        return false
    end
    local ok, reason = validateInviteAcceptance(invite)
    if not ok then
        table.insert(pendingInvites, invite)
        ui_message(reason or "Cannot accept this invite.", 6, "warning", "warning")
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
        return false
    end
    invite.attendance = attendanceLevels[level] or invite.attendance or attendanceLevels.MEDIUM
    rsvpData = invite
    startCarMeet(rsvpData.location, rsvpData.type, rsvpData.attendance, rsvpData.clubId)
    career_saveSystem.saveCurrent()
    return true
end

local function updateAttendance(level)
    if not rsvpData then return end
    rsvpData.attendance = attendanceLevels[level] or 2
end

local function decline(inviteId)
    local invite = removePendingInvite(inviteId)
    applyInvitePenalty(invite, "declined invite")
    -- A pending invite does not own the active route. Declining it must not
    -- disturb navigation for an active meet or another career activity.
    generationInterval = DEFAULT_INVITE_GENERATION_INTERVAL
    lastGenerationTime = os.time()
    career_saveSystem.saveCurrent()
end

local function cancelRSVP()
    applyInvitePenalty(rsvpData, "abandoned accepted invite", {sceneRep = true})
    if rsvpData and rsvpData.type == "BAZAAR" then
        ui_message(ACCEPTED_INVITE_MISS_MESSAGE, 8, "warning", "warning")
    end
    rsvpData = nil
    meetRoute.clear()
    cleanupPreviousMeet()
    generationInterval = DEFAULT_INVITE_GENERATION_INTERVAL
    lastGenerationTime = os.time()
    career_saveSystem.saveCurrent()
end

local function setRoute()
    if not rsvpData then return end
    if not ensureCarmeetSitesForCurrentLevel() then return end
    local meet = carmeetLocations[rsvpData.location]
    if not meet then
        print("Car meet location not found: " .. rsvpData.location)
        return
    end

    local availableSpots = deepcopy(meet.parkingSpots)

    local playerSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(be:getPlayerVehicleID(0), availableSpots)

    local options = {
        color = {1, 0.4, 0},
        step = 4,
        renderDecals = true
    }
    meetRoute.set(playerSpot.pos, options)
end

local function checkMeetStart()
    -- Invite-based meets start when accepted. This remains as a compatibility
    -- hook for the old scheduled flow.
end

local function onUpdate(dtReal, dtSim, dtRaw)
    if not career_career.isActive() then return end

    if not ensureCarmeetSitesForCurrentLevel() then
        if meetState.active then
            cleanupPreviousMeet()
        end
        return
    end
    
    local currentTime = os.time()
    if currentTime - lastUpdateCheck >= updateInterval then
        lastUpdateCheck = currentTime
        checkAvailableMeets()
        checkMeetStart()
        
        if meetState.active and currentTime % VEHICLE_UPDATE_INTERVAL == 0 then
            updateVehicleVisibility()
        end
        
        if meetState.active and meetState.phase == "waiting" then
            if isPlayerAtMeetArrivalPoint() then
                local meetType = meetTypes[meetState.type]
                if not meetType then return end
                
                local reputation = 0
                local attendanceMessage = nil
                local reputationMultiplier = meetType.baseReputationMultiplier
                if reputationMultiplier == nil then reputationMultiplier = 1 end
                if reputationMultiplier ~= 0 then
                    reputation, attendanceMessage = calculateAttendanceReputation()
                    reputation = reputation * reputationMultiplier
                end
                local message = meetType.actions.onArrival(reputation)
                if attendanceMessage then
                    message = message .. "\n" .. attendanceMessage
                end
                local popularity = awardVehiclePopularityForMeet()
                if popularity and popularity.amountPercent and popularity.amountPercent > 0 then
                    message = message .. string.format("\nLocal buzz increased by %.2f%%.", popularity.amountPercent)
                elseif popularity and popularity.capped then
                    message = message .. "\nThis car is already well known locally."
                end
                ui_message(message, 10, "info", "info")
                
                if reputation > 0 then
                    local meetVehicleId = getMeetVehicleInventoryId(meetState)
                    local _, arrivalMult, arrivalAdjusted = addPlayerMeetReputationForVehicle(reputation, meetVehicleId, "arrived at car meet")
                    if meetVehicleId then
                        awardCarRep(meetVehicleId, 1, "meet arrival")
                        appendMeetSceneEvent(meetVehicleId, {
                            kind = "meet_arrival",
                            label = (meetTypes[meetState.type] and meetTypes[meetState.type].name) or meetState.type,
                            location = rsvpData and rsvpData.location or nil,
                            meetType = meetState.type,
                            playerRep = arrivalAdjusted,
                            carRepDelta = 1
                        })
                    end
                end
                if rsvpData and rsvpData.clubId and meetState.flags and not meetState.flags.clubAttendanceTracked then
                    recordClubMeetResult(rsvpData.clubId, true, "attended club meet")
                    meetState.flags.clubAttendanceTracked = true
                end
                meetRoute.clear()
                
                meetState.phase = "showcase"
                meetState.arrivalTime = currentTime
                meetState.flags.playerBroughtVehicle = didPlayerBringVehicleToMeet()
                if not meetState.flags.saleInventoryId then
                    meetState.flags.saleInventoryId = resolveMeetSaleInventoryId()
                end
                if meetState.flags.saleInventoryId and meetState.flags.playerBroughtVehicle then
                    initializeMeetSaleOnArrival(meetState, currentTime)
                end
                if gameplay_rawPois and gameplay_rawPois.clear then
                    gameplay_rawPois.clear()
                end
                career_saveSystem.saveCurrent()
                guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
            end
        end
        
        if meetState.active and meetState.phase == "showcase" then
            local meetType = meetTypes[meetState.type]
            if meetType and currentTime - meetState.arrivalTime > meetType.showcaseDuration then
                if meetType.actions and meetType.actions.onShowcaseEnd then
                    meetType.actions.onShowcaseEnd(meetState)
                end
            end
            if meetState.flags and not meetState.flags.playerSoldSaleVehicle then
                if not meetState.flags.saleInventoryId then
                    meetState.flags.saleInventoryId = resolveMeetSaleInventoryId()
                end
                if meetState.flags.saleInventoryId and not meetState.flags.playerBroughtVehicle and didPlayerBringVehicleToMeet() then
                    meetState.flags.playerBroughtVehicle = true
                    if not meetState.flags.saleInitialized then
                        initializeMeetSaleOnArrival(meetState, currentTime)
                    end
                    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
                end
            end
        end
        
        if meetState.active and meetState.type then
            if meetState.flags and not meetState.flags.saleInventoryId and meetState.phase ~= "cleanup" and meetState.phase ~= "ending" then
                local resolved = resolveMeetSaleInventoryId()
                if resolved then
                    meetState.flags.saleInventoryId = resolved
                    meetState.flags.playerSoldSaleVehicle = false
                end
            end
            local meetType = meetTypes[meetState.type]
            if meetType and meetType.onUpdate then
                meetType.onUpdate(meetState, currentTime)
            end
            updateMeetSaleOffers(meetState, currentTime)
            if canPlayerSellAtMeet(meetState) then
                guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
            end
        end
        
        if meetState.active and meetState.phase == "ending" then
            local meetType = meetTypes[meetState.type]
            
            if not meetState.flags.dispersalStarted then
                meetState.flags.vehiclesToLeave = {}
                for _, vehID in ipairs(spawnedMeetVehicles) do
                    table.insert(meetState.flags.vehiclesToLeave, vehID)
                end
                meetState.flags.lastVehicleLeaveTime = currentTime
                meetState.flags.dispersalStarted = true
                -- Drop showcase inspect/sale markers immediately so they don't stick at the
                -- player's last location after leaving the meet.
                meetRoute.clear()
                if gameplay_rawPois and gameplay_rawPois.clear then
                    gameplay_rawPois.clear()
                end
            end
            
            if #meetState.flags.vehiclesToLeave > 0 and currentTime - meetState.flags.lastVehicleLeaveTime >= MEET_LEAVE_INTERVAL then
                local vehID = table.remove(meetState.flags.vehiclesToLeave, 1)
                local veh = getObjectByID(vehID)
                if veh then
                    veh:queueLuaCommand('ai.setMode("traffic")')
                    veh:queueLuaCommand('ai.setSpeedMode("legal")')
                end
                meetState.flags.lastVehicleLeaveTime = currentTime
            end
            
            if #meetState.flags.vehiclesToLeave == 0 then
                if meetType and meetType.actions and meetType.actions.onLeave then
                    local message = meetType.actions.onLeave()
                    ui_message(message, 10, "info", "info")
                end
                meetState.phase = "cleanup"
                career_saveSystem.saveCurrent()
                guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
            end
        end
        
        if meetState.phase == "cleanup" then
            local playerPos = getPlayerReferencePosition()

            for i = #spawnedMeetVehicles, 1, -1 do
                local vehID = spawnedMeetVehicles[i]
                local veh = getObjectByID(vehID)
                if not veh then
                    table.remove(spawnedMeetVehicles, i)
                elseif not playerPos then
                    -- No player position (edge case): despawn immediately so cleanup can't stall.
                    table.remove(spawnedMeetVehicles, i)
                    gameplay_traffic.removeTraffic(vehID)
                    veh:delete()
                else
                    local distance = (playerPos - veh:getPosition()):length()
                    if distance > MEET_CLEANUP_DISTANCE then
                        table.remove(spawnedMeetVehicles, i)
                        gameplay_traffic.removeTraffic(vehID)
                        veh:delete()
                    end
                end
            end
            
            if #spawnedMeetVehicles == 0 then
                if rsvpData and rsvpData.type == "BAZAAR" and (tonumber(meetState.arrivalTime) or 0) <= 0 then
                    applyInvitePenalty(rsvpData, "missed bazaar after RSVP", {sceneRep = true})
                    ui_message(ACCEPTED_INVITE_MISS_MESSAGE, 8, "warning", "warning")
                end
                rsvpData = nil
                cleanupPreviousMeet()
                career_saveSystem.saveCurrent()
            end
        end
    end
end

M.requestRSVPData = function()
    print("requestRSVPData")
    guihooks.trigger('onRSVPData', rsvpData)
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
end

local function getMeetTypes()
    local types = {}
    for typeKey, meetType in pairs(meetTypes) do
        table.insert(types, {
            key = typeKey,
            name = meetType.name,
            description = meetType.description,
            reputationMultiplier = meetType.baseReputationMultiplier,
            showcaseDuration = meetType.showcaseDuration,
            preferredTimes = meetType.preferredTimes,
            timeWindow = meetType.timeWindow
        })
    end
    return types
end

local function getCurrentMeetType()
    if meetState.active and meetState.type then
        return getMeetType(meetState.type)
    elseif rsvpData and rsvpData.type then
        return getMeetType(rsvpData.type)
    end
    return nil
end

local function getMeetState()
    return meetState
end

M.registerMeetType = function(key, meetTypeData)
    meetTypeData.showcaseDuration = meetTypeData.showcaseDuration or 600
    
    meetTypeData.preferredTimes = meetTypeData.preferredTimes or {0.417, 0.458, 0.500}
    meetTypeData.timeWindow = meetTypeData.timeWindow or 0.02
    
    if not meetTypeData.actions then
        meetTypeData.actions = {}
    end
    if not meetTypeData.actions.onShowcaseEnd then
        meetTypeData.actions.onShowcaseEnd = function(state)
            state.phase = "ending"
            state.flags.dispersalStarted = false
            clearMeetShowcasePois(state)
            ui_message("Meet is over, vehicles starting to leave!", 10, "info", "info")
        end
    end
    
    meetTypes[key] = meetTypeData
    print("Registered new meet type: " .. meetTypeData.name)
end

M.onSaveCurrentProfile = persist.onSaveCurrentProfile

local function addTransactionReputation(kind, price, marketValue)
    if not meetState.active then return playerMeetReputation end
    price = tonumber(price) or 0
    marketValue = math.max(tonumber(marketValue) or 0, 1)
    local rep = 0
    if kind == "buy" then
        rep = math.min(5, math.max(0, inverseLerp(marketValue, marketValue * 1.3, price) * 5))
    elseif kind == "sell" then
        rep = math.min(5, math.max(0, inverseLerp(marketValue * 0.7, marketValue, price) * 5))
    end
    if rep > 0 then
        local transactionVehicleId = meetState.flags and meetState.flags.saleInventoryId or getCurrentInventoryId()
        local _, _, adjustedRep = addPlayerMeetReputationForVehicle(rep, transactionVehicleId, "car meet " .. tostring(kind) .. " transaction")
        if transactionVehicleId then
            awardCarRep(transactionVehicleId, kind == "sell" and 2 or 0.5, "meet transaction")
            appendMeetSceneEvent(transactionVehicleId, {
                kind = "transaction",
                label = kind == "sell" and "Sold at meet" or "Bought at meet",
                playerRep = adjustedRep,
                carRepDelta = kind == "sell" and 2 or 0.5,
                meetType = meetState.type,
                price = price
            })
        end
        career_saveSystem.saveCurrent()
    end
    return playerMeetReputation
end

local function applyLowballPenalty(offerValue, marketValue)
    -- Lowball offers no longer affect scene reputation (only Car Bazaar RSVP miss does).
    return playerMeetReputation
end

local function onMarketplaceVehicleSold(inventoryId, salePrice, marketValue)
    if meetState.active and meetState.flags and tostring(meetState.flags.saleInventoryId) == tostring(inventoryId) then
        meetState.flags.playerSoldSaleVehicle = true
    end
    if meetState.active and meetState.type == "BAZAAR" and tostring(meetState.flags.bazaarInventoryId) == tostring(inventoryId) then
        meetState.flags.playerSoldBazaarVehicle = true
        ui_message("Bazaar sale complete.", 5, "info", "info")
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    end
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
    addTransactionReputation("sell", salePrice, marketValue)
end

local function getMeetSaleOfferData()
    return buildMeetSaleOverviewPayload()
end

local function setMeetSaleAskingPrice(value)
    if not meetState.active or not meetState.flags then return false end
    local listing = meetState.flags.saleListing or ensureMeetSaleState(meetState)
    if not listing then return false end
    local marketValue = math.max(tonumber(listing.marketValue) or 0, 50)
    local minPrice = math.max(50, marketValue * 0.5)
    local maxPrice = math.max(minPrice, marketValue * 2.0)
    local askingPrice = math.floor((math.max(minPrice, math.min(maxPrice, tonumber(value) or marketValue)) + 25) / 50) * 50
    listing.value = askingPrice
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    guihooks.trigger('onCarMeetSaleOfferData', getMeetSaleOfferData())
    return getMeetSaleOfferData()
end

local function openMeetSaleOffers()
    local data = getMeetSaleOfferData()
    if not data then
        ui_message("Bring a vehicle to the meet during showcase to receive offers.", 5, "info", "info")
        return false
    end
    extensions.ui_router.navigate('carMeetOffers')
    core_jobsystem.create(function(job)
        job.sleep(0.1)
        guihooks.trigger('onCarMeetSaleOfferData', getMeetSaleOfferData() or data)
    end)
    return true
end

local function requestMeetSaleOfferData()
    guihooks.trigger('onCarMeetSaleOfferData', getMeetSaleOfferData())
end

local function acceptBazaarOffer(offerIndex)
    return M.acceptCarMeetOfferWithValue(offerIndex)
end

local function acceptCarMeetOfferWithValue(offerIndex, negotiatedValue)
    if not meetState.active or not meetState.flags or not canPlayerSellAtMeet(meetState) then return false end
    local inventoryId = meetState.flags.saleInventoryId
    local listing = meetState.flags.saleListing or ensureMeetSaleState(meetState)
    local offers = meetState.flags.saleOffers or {}
    offerIndex = tonumber(offerIndex)
    local offer = offerIndex and offers[offerIndex]
    if not inventoryId or not listing or not offer then return false end

    local salePrice = tonumber(negotiatedValue) or tonumber(offer.value) or 0
    table.remove(offers, offerIndex)
    meetState.flags.playerSoldSaleVehicle = true
    if meetState.type == "BAZAAR" then
        meetState.flags.playerSoldBazaarVehicle = true
        ui_message("Bazaar sale complete.", 5, "info", "info")
    else
        ui_message("Vehicle sold to a car meet buyer.", 5, "info", "info")
    end
    if career_modules_inventory and career_modules_inventory.sellVehicle then
        career_modules_inventory.sellVehicle(inventoryId, salePrice)
    end
    addTransactionReputation("sell", salePrice, listing.marketValue)
    if gameplay_rawPois and gameplay_rawPois.clear then
        gameplay_rawPois.clear()
    end
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    return true
end

local function declineBazaarOffer(offerIndex)
    if not meetState.active or not meetState.flags then return false end
    local offers = meetState.flags.saleOffers or {}
    offerIndex = tonumber(offerIndex)
    if not offerIndex or not offers[offerIndex] then return false end
    table.remove(offers, offerIndex)
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    return true
end

local function disableCarMeetOfferNegotiation(offerIndex)
    if not meetState.active or not meetState.flags then return false end
    local offers = meetState.flags.saleOffers or {}
    offerIndex = tonumber(offerIndex)
    if not offerIndex or not offers[offerIndex] then return false end
    offers[offerIndex].negotiationPossible = false
    guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    return true
end

local function negotiateBazaarOffer(offerIndex)
    if not meetState.active or not meetState.flags then return false end
    local listing = meetState.flags.saleListing or ensureMeetSaleState(meetState)
    local offers = meetState.flags.saleOffers or {}
    offerIndex = tonumber(offerIndex)
    local offer = offerIndex and offers[offerIndex]
    if not listing or not offer or not career_modules_marketplace or not career_modules_marketplace.startCarMeetBuyingOffer then return false end
    career_modules_marketplace.startCarMeetBuyingOffer({
        inventoryId = meetState.flags.saleInventoryId,
        niceName = (core_locales and core_locales.translateWithOrWithoutContext and listing.niceName)
            and core_locales.translateWithOrWithoutContext(listing.niceName) or listing.niceName,
        thumbnail = listing.thumbnail,
        value = listing.value,
        marketValue = listing.marketValue
    }, offer, offerIndex)
    return true
end

local function startPurchaseOffer(shopId)
    shopId = tonumber(shopId)
    if not shopId then return false end
    if not meetState.active then
        ui_message("No active car meet purchase opportunity.", 5, "warning", "warning")
        return false
    end
    if career_modules_vehicleShopping and career_modules_vehicleShopping.canPurchaseCarMeetVehicle then
        if not career_modules_vehicleShopping.canPurchaseCarMeetVehicle(true) then
            return false
        end
    end
    if career_modules_marketplace and career_modules_marketplace.startNegotiateSellingOffer then
        career_modules_marketplace.startNegotiateSellingOffer(shopId)
        return true
    end
    return false
end

local function isWalkingForMeetInteraction()
    return gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() == true
end

local function getMeetVehiclePoiPosition(entry)
    local veh = entry and entry.vehicleId and getObjectByID(entry.vehicleId)
    if veh then return veh:getPosition() end
    return entry and entry.pos or nil
end

local function getPlayerSalePoiPosition()
    -- Prefer the meet parking spot so the offers pin cannot follow the player vehicle around the map.
    if meetState.playerSpot and meetState.playerSpot.pos then
        return vec3(meetState.playerSpot.pos)
    end
    local veh = meetState.flags and meetState.flags.saleVehicleId and getObjectByID(meetState.flags.saleVehicleId)
    if veh then return veh:getPosition() end
    return nil
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
    if not career_career.isActive() or not meetState.active or meetState.phase ~= "showcase" then return end

    for _, entry in ipairs(carMeetPurchaseVehicles or {}) do
        local pos = getMeetVehiclePoiPosition(entry)
        if pos then
            table.insert(elements, {
                id = "inspectVehicleMarker##carMeetPurchaseVehicle-" .. tostring(entry.shopId),
                data = {
                    type = "carMeetPurchaseVehicle",
                    shopId = entry.shopId,
                    name = entry.name,
                    sellerName = entry.sellerName
                },
                markerInfo = {
                    inspectVehicleMarker = {
                        pos = pos,
                        radius = entry.markerRadius or 5,
                        vehicleHeight = 4
                    }
                }
            })
        end
    end

    if canPlayerSellAtMeet(meetState) then
        local pos = getPlayerSalePoiPosition()
        if pos then
            local offers = meetState.flags.saleOffers or {}
            table.insert(elements, {
                id = "inspectVehicleMarker##carMeetPlayerSaleOffers-" .. tostring(meetState.flags.saleInventoryId),
                data = {
                    type = "carMeetPlayerSaleOffers",
                    inventoryId = meetState.flags.saleInventoryId,
                    offerCount = #offers
                },
                markerInfo = {
                    inspectVehicleMarker = {
                        pos = pos,
                        radius = 5,
                        vehicleHeight = 4
                    }
                }
            })
        end
    end
end

local function onActivityAcceptGatherData(elemData, activityData)
    if not meetState.active or meetState.phase ~= "showcase" then return end
    if not isWalkingForMeetInteraction() then return end

    for _, elem in ipairs(elemData or {}) do
        if elem.type == "carMeetPurchaseVehicle" then
            local blockReason = career_modules_vehicleShopping and career_modules_vehicleShopping.getCarMeetPurchaseBlockReason and career_modules_vehicleShopping.getCarMeetPurchaseBlockReason() or nil
            local props = {
                {
                    icon = "person",
                    keyLabel = "Seller",
                    valueLabel = elem.sellerName or "Car Meet Owner"
                }
            }
            if blockReason then
                table.insert(props, {
                    icon = "abandon",
                    keyLabel = "Garage",
                    valueLabel = blockReason
                })
            end
            table.insert(activityData, {
                icon = "carDealer",
                heading = elem.name or "Meet Vehicle",
                preheadings = {"Car Meet Sale"},
                sorting = {
                    type = elem.type,
                    id = elem.shopId
                },
                props = props,
                buttonLabel = "Make an Offer",
                startable = blockReason == nil,
                disableReason = blockReason,
                buttonFun = function() startPurchaseOffer(elem.shopId) end
            })
        elseif elem.type == "carMeetPlayerSaleOffers" then
            table.insert(activityData, {
                icon = "dialogOutline",
                heading = "Offers on Your Car",
                preheadings = {"Car Meet Buyers"},
                sorting = {
                    type = elem.type,
                    id = elem.inventoryId
                },
                props = {
                    {
                        icon = "dialogOutline",
                        keyLabel = "Offers",
                        valueLabel = tostring(elem.offerCount or 0)
                    }
                },
                buttonLabel = "View Offers",
                buttonFun = openMeetSaleOffers
            })
        end
    end
end

local getCarMeetPurchaseEntry
local getCarMeetVehicleIdForShopId
local snapshotCarMeetVehicleForPurchase
local prepareCarMeetVehicleForPurchase
local onCarMeetVehiclePurchased

do
    local function resolveCarMeetPaintNames(shopId, shopVehicleInfo)
        local entry = getCarMeetPurchaseEntry(shopId)
        if entry and type(entry.paintNames) == "table" and entry.paintNames[1] then
            return entry.paintNames, entry.modelKey
        end
        if shopVehicleInfo and type(shopVehicleInfo.paintNames) == "table" and shopVehicleInfo.paintNames[1] then
            local modelKey = shopVehicleInfo.model_key or shopVehicleInfo.modelKey
            return shopVehicleInfo.paintNames, modelKey
        end
        return nil, entry and entry.modelKey or shopVehicleInfo and (shopVehicleInfo.model_key or shopVehicleInfo.modelKey)
    end

    function getCarMeetPurchaseEntry(shopId)
        shopId = tonumber(shopId)
        if not shopId then return nil end
        for _, entry in ipairs(carMeetPurchaseVehicles) do
            if tonumber(entry.shopId) == shopId then
                return entry
            end
        end
        return nil
    end

    function getCarMeetVehicleIdForShopId(shopId)
        local entry = getCarMeetPurchaseEntry(shopId)
        return entry and entry.vehicleId or nil
    end

    function snapshotCarMeetVehicleForPurchase(vehId)
        vehId = tonumber(vehId)
        if not vehId then return false end
        local vehicleData = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
        if not vehicleData or type(vehicleData.config) ~= "table" then return false end
        vehicleData.config = deepcopy(vehicleData.config)
        return true
    end

    function prepareCarMeetVehicleForPurchase(shopId, shopVehicleInfo)
        shopId = tonumber(shopId)
        if not shopId then return nil end
        local vehId = getCarMeetVehicleIdForShopId(shopId)
        if not vehId or not getObjectByID(vehId) then return nil end

        local paintNames, modelKey = resolveCarMeetPaintNames(shopId, shopVehicleInfo)
        if paintNames then
            applyRandomPaintToSpawnedVehicle(vehId, paintNames, modelKey)
        end
        snapshotCarMeetVehicleForPurchase(vehId)
        return vehId
    end

    function onCarMeetVehiclePurchased(shopId, keepVehicle)
        shopId = tonumber(shopId)
        if not shopId then return end
        for i = #carMeetPurchaseVehicles, 1, -1 do
            local entry = carMeetPurchaseVehicles[i]
            if tonumber(entry.shopId) == shopId then
                local veh = entry.vehicleId and getObjectByID(entry.vehicleId)
                if veh and not keepVehicle then
                    gameplay_traffic.removeTraffic(entry.vehicleId)
                    veh:delete()
                elseif veh and keepVehicle then
                    gameplay_traffic.removeTraffic(entry.vehicleId)
                    veh.playerUsable = true
                    veh:queueLuaCommand('ai.setMode("disabled")')
                    veh:queueLuaCommand('electrics.setIgnitionLevel(0)')
                    veh:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
                    veh:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')
                end
                for j = #spawnedMeetVehicles, 1, -1 do
                    if tonumber(spawnedMeetVehicles[j]) == tonumber(entry.vehicleId) then
                        table.remove(spawnedMeetVehicles, j)
                        break
                    end
                end
                table.remove(carMeetPurchaseVehicles, i)
                break
            end
        end
        if gameplay_rawPois and gameplay_rawPois.clear then
            gameplay_rawPois.clear()
        end
        guihooks.trigger('onCarMeetOverview', getCarMeetOverview())
    end
end

local function onCareerActive(active)
    careerActive = active
    if not active then
        persist.reset()
    elseif career_career.isActive() then
        persist.load(nil)
    end
end

M.onExtensionLoaded = onExtensionLoaded
M.getCarMeetLocations = getCarMeetLocations
M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate
M.onCareerActive = onCareerActive
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData

M.checkAvailableMeets = checkAvailableMeets
M.rsvpToMeet = rsvpToMeet
M.decline = decline
M.cancelRSVP = cancelRSVP
M.updateAttendance = updateAttendance
M.setRoute = setRoute
M.cleanupPreviousMeet = cleanupPreviousMeet
M.getCarMeetOverview = getCarMeetOverview
M.requestPopularityData = requestCarMeetPopularityData
M.requestVehicleHistory = requestVehicleHistory
M.addPlayerMeetReputation = addPlayerMeetReputation
M.debugGenerateInvite = generateInviteNow
M.debugGenerateInviteOfType = generateInviteOfType
M.debugAdjustReputation = debugAdjustReputation
M.debugClearInvites = clearPendingInvites
M.debugAccelerateInvite = debugAccelerateInvite
M.debugDumpState = dumpDebugState
M.getClubUiData = getClubUiData
M.joinClub = joinClub
M.leaveClub = leaveClub
M.addTransactionReputation = addTransactionReputation
M.applyLowballPenalty = applyLowballPenalty
M.onMarketplaceVehicleSold = onMarketplaceVehicleSold
M.acceptBazaarOffer = acceptBazaarOffer
M.acceptCarMeetOfferWithValue = acceptCarMeetOfferWithValue
M.declineBazaarOffer = declineBazaarOffer
M.disableCarMeetOfferNegotiation = disableCarMeetOfferNegotiation
M.negotiateBazaarOffer = negotiateBazaarOffer
M.getMeetSaleOfferData = getMeetSaleOfferData
M.requestMeetSaleOfferData = requestMeetSaleOfferData
M.setMeetSaleAskingPrice = setMeetSaleAskingPrice
M.setCarMeetSaleAskingPrice = setMeetSaleAskingPrice
M.openMeetSaleOffers = openMeetSaleOffers
M.startPurchaseOffer = startPurchaseOffer
M.getCarMeetVehicleIdForShopId = getCarMeetVehicleIdForShopId
M.prepareCarMeetVehicleForPurchase = prepareCarMeetVehicleForPurchase
M.snapshotCarMeetVehicleForPurchase = snapshotCarMeetVehicleForPurchase
M.onCarMeetVehiclePurchased = onCarMeetVehiclePurchased

M.requestRSVPData = M.requestRSVPData

M.startCarMeet = startCarMeet

function M.notifyOnPhoneAppInstalled()
    if not career_career or not career_career.isActive or not career_career.isActive() then
        return
    end
    if #pendingInvites == 0 then
        return
    end
    firePhoneLockNotification(pendingInvites[#pendingInvites])
end

return M
