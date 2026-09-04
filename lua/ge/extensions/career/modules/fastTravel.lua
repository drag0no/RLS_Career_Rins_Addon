local M = {}

M.dependencies = {
  "career_career",
  "career_modules_payment",
  "career_modules_quickTravel"
}

local config
local configLevelId
local sites
local placesById = {}
local places = {}
local canPay

local function notify(msg, category)
  ui_message(msg, 5, category or "info", category or "info")
end

local function currentLevelId()
  return getCurrentLevelIdentifier()
end

local function configPathForLevel(levelId)
  return levelId and ("/levels/" .. levelId .. "/fastTravel.config.json") or nil
end

local function asVec3(value, fallback)
  if type(value) == "table" then return vec3(value[1] or 0, value[2] or 0, value[3] or 0) end
  return value or fallback or vec3()
end

local function getFirstTag(spot)
  local tags = spot.customFields and spot.customFields.tags
  if type(tags) == "table" then return tags[1] or tags[0] end
  return nil
end

local function spotDirection(spot)
  local rot = spot and spot.rot
  if not rot then return vec3(0, 1, 0) end
  local q = rot
  if type(rot) == "table" then
    q = quat(rot[1] or 0, rot[2] or 0, rot[3] or 0, rot[4] or 1)
  end
  local dir = q * vec3(0, 1, 0)
  dir.z = 0
  if dir:length() < 1e-4 then return vec3(0, 1, 0) end
  return dir:normalized()
end

local function resetCache()
  config = nil
  configLevelId = nil
  sites = nil
  placesById = {}
  places = {}
end

local function loadConfig(levelId)
  levelId = levelId or currentLevelId()
  if not levelId then return nil end
  if config and configLevelId == levelId then return config end

  resetCache()
  configLevelId = levelId
  config = jsonReadFile(configPathForLevel(levelId))
  if type(config) ~= "table" then
    config = nil
    return nil
  end
  config.defaults = config.defaults or {}
  return config
end

local function loadSites(levelId)
  if sites then return sites end
  local cfg = loadConfig(levelId)
  if not cfg or not cfg.sitesFile then return nil end

  sites = jsonReadFile(cfg.sitesFile) or {}
  local spotsByName = {}
  for _, raw in ipairs(sites.parkingSpots or {}) do
    if raw.name then
      spotsByName[raw.name] = raw
    end
  end

  placesById = {}
  places = {}
  for _, rawPlace in ipairs(cfg.places or {}) do
    local defaults = cfg.defaults or {}
    local enabled = rawPlace.enabled
    if enabled == nil then enabled = defaults.enabled ~= false end
    local spot = spotsByName[rawPlace.spot or rawPlace.id]
    if enabled and spot then
      local mode = rawPlace.mode or defaults.mode or "walk"
      local place = {
        id = rawPlace.id or spot.name,
        spotId = spot.name,
        label = rawPlace.label or getFirstTag(spot) or spot.name,
        mode = mode,
        allowVehicle = rawPlace.allowVehicle == true or mode == "vehicle",
        priceSource = rawPlace.priceSource or defaults.priceSource or "taxi",
        priceMultiplier = tonumber(rawPlace.priceMultiplier or defaults.priceMultiplier) or 1,
        vehiclePriceMultiplier = tonumber(rawPlace.vehiclePriceMultiplier or defaults.vehiclePriceMultiplier) or 15,
        vehicleBaseFee = tonumber(rawPlace.vehicleBaseFee or defaults.vehicleBaseFee) or 250,
        pos = asVec3(spot.pos),
        rot = spot.rot,
        direction = spotDirection(spot)
      }
      placesById[place.id] = place
      table.insert(places, place)
    end
  end
  return sites
end

local function isConfiguredCareer(levelId)
  local cfg = loadConfig(levelId or currentLevelId())
  local current = currentLevelId()
  return cfg
    and current
    and current == (cfg.levelId or levelId or current)
    and career_career
    and career_career.isActive
    and career_career.isActive()
end

local function closeToPlay()
  if career_career and career_career.closeAllMenus then career_career.closeAllMenus() end
  if guihooks and guihooks.trigger then
    guihooks.trigger("ChangeState", { state = "play", params = {} })
  end
end

local function baseTaxiPrice(pos)
  if not career_modules_quickTravel or not career_modules_quickTravel.getPriceForQuickTravel then return 0 end
  local ok, price = pcall(career_modules_quickTravel.getPriceForQuickTravel, pos)
  if ok and tonumber(price) then return tonumber(price) end
  return 0
end

local function priceForPlace(place)
  if not place then return 0 end
  local price = baseTaxiPrice(place.pos)
  if place.allowVehicle then
    price = price * (place.vehiclePriceMultiplier or 15) + (place.vehicleBaseFee or 250)
  end
  price = price * (place.priceMultiplier or 1)
  return math.max(0, math.floor(price * 100 + 0.5) / 100)
end

local function moneyCost(amount)
  return { money = { amount = amount, canBeNegative = false } }
end

function canPay(amount)
  if amount <= 0 then return true end
  return not career_modules_payment.canPay or career_modules_payment.canPay(moneyCost(amount))
end

local function destinationPayload(originId)
  loadSites()
  local cfg = config or {}
  local origin = placesById[originId]
  local destinations = {}
  for _, destination in ipairs(places) do
    if destination.id ~= originId then
      local price = priceForPlace(destination)
      table.insert(destinations, {
        id = destination.id,
        label = destination.label,
        mode = destination.allowVehicle and "vehicle" or "walk",
        price = price,
        canPay = canPay(price)
      })
    end
  end
  return {
    visible = true,
    payload = {
      title = cfg.title or "Fast Travel",
      subtitle = cfg.subtitle or (origin and origin.label) or "Travel",
      originId = originId,
      originLabel = origin and origin.label or "Current Stop",
      destinations = destinations
    }
  }
end

local function pay(amount, label)
  if amount <= 0 then return true end
  if not canPay(amount) then return false end
  career_modules_payment.pay(moneyCost(amount), { label = label or "Fast travel" })
  return true
end

local function faceTravelDirection(place)
  if not place or not place.direction then return end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() and gameplay_walk.setRot then
    gameplay_walk.setRot(place.direction, vec3(0, 0, 1))
  end
end

local function travelWithPlayer(place)
  if gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(true)
  end
  local player = getPlayerVehicle(0)
  if player and spawn and spawn.safeTeleport then
    spawn.safeTeleport(player, place.pos)
  end
  faceTravelDirection(place)
end

local function travelWithVehicle(place)
  local veh = getPlayerVehicle(0)
  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, place.pos, quatFromDir(place.direction))
  end
end

function M.travelTo(placeId)
  if not isConfiguredCareer() then return end
  loadSites()
  local place = placesById[placeId]
  if not place then
    notify("Fast travel destination is not available.", "warning")
    return
  end

  local amount = priceForPlace(place)
  if not canPay(amount) then
    notify("Insufficient funds for fast travel.", "warning")
    return
  end

  if place.allowVehicle then
    if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
      notify("Enter your vehicle before using vehicle fast travel.", "warning")
      return
    end
    if not getPlayerVehicle(0) then
      notify("No player vehicle found.", "warning")
      return
    end
  end

  if not pay(amount, "Fast travel to " .. place.label) then
    notify("Insufficient funds for fast travel.", "warning")
    return
  end
  if place.allowVehicle then
    travelWithVehicle(place)
  else
    travelWithPlayer(place)
  end
  if gameplay_police and gameplay_police.ignoreSpeedingAfterTeleport then
    gameplay_police.ignoreSpeedingAfterTeleport()
  end
  if guihooks and guihooks.trigger then guihooks.trigger("CareerFastTravelUi", { visible = false }) end
  closeToPlay()
end

function M.openTravelMenu(originId)
  if not isConfiguredCareer() then return end
  if career_career and career_career.closeAllMenus then career_career.closeAllMenus() end
  if guihooks and guihooks.trigger then guihooks.trigger("CareerFastTravelUi", destinationPayload(originId)) end
end

function M.closeTravelMenu()
  if guihooks and guihooks.trigger then guihooks.trigger("CareerFastTravelUi", { visible = false }) end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  local cfg = loadConfig(levelIdentifier)
  if not cfg or levelIdentifier ~= (cfg.levelId or levelIdentifier) or not isConfiguredCareer(levelIdentifier) then return end
  loadSites(levelIdentifier)
  for _, place in ipairs(places) do
    table.insert(elements, {
      id = "careerFastTravel-" .. place.id,
      data = {
        type = "careerFastTravel",
        action = "origin",
        placeId = place.id,
        name = place.label
      },
      markerInfo = {
        inspectVehicleMarker = {
          pos = place.pos,
          radius = 18,
          vehicleHeight = 4
        },
        bigmapMarker = {
          pos = place.pos,
          icon = cfg.icon or "poi_fasttravel_round_orange_green",
          name = place.label,
          description = cfg.description or "Fast travel"
        },
        clusterType = "activity"
      },
      pos = place.pos,
      radius = 18
    })
  end
end

function M.onActivityAcceptGatherData(elemData, activityData)
  if not isConfiguredCareer() then return end
  loadSites()
  local cfg = config or {}
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "careerFastTravel" and elem.action == "origin" then
      local originId = elem.placeId
      table.insert(activityData, {
        icon = cfg.activityIcon or "fastTravel",
        heading = elem.name or "Fast Travel",
        preheadings = { cfg.subtitle or "Fast Travel" },
        sorting = {
          type = elem.type,
          id = originId
        },
        startable = true,
        buttonLabel = cfg.buttonLabel or "Travel",
        buttonFun = function() M.openTravelMenu(originId) end
      })
    end
  end
end

function M.onExtensionLoaded()
  loadConfig()
  loadSites()
end

function M.onClientStartMission()
  resetCache()
  if not isConfiguredCareer() then return end
  loadSites()
end

function M.onCareerActivated()
  resetCache()
  if not isConfiguredCareer() then return end
  loadSites()
end

return M
