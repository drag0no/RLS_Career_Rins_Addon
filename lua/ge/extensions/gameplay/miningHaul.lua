local M = {}

M.dependencies = {"gameplay_physicalCargo"}

local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = SAVE_DIR .. "/miningHaul.json"

local config = nil
local sites = nil
local loadedLevel = nil
local configChecked = false
local sitesChecked = false
local lastUiMode = nil
local uiTimer = 0
local checkTimer = 0
local pickupPromptState = nil

local state = {
  active = false,
  phase = "idle",
  truckId = nil,
  inventoryId = nil,
  loaderId = nil,
  currentPickupIndex = 0,
  propIds = {},
  deliveredThisRun = 0,
  deliveriesCompleted = 0,
  oreDelivered = 0,
  diamondsFound = 0,
  grossEarnings = 0,
  repairCosts = 0
}

local function resetShiftProgress()
  state.phase = "idle"
  state.truckId = nil
  state.inventoryId = nil
  state.loaderId = nil
  state.currentPickupIndex = 0
  state.propIds = {}
  state.deliveredThisRun = 0
  state.deliveriesCompleted = 0
  state.oreDelivered = 0
  state.diamondsFound = 0
  state.grossEarnings = 0
  state.repairCosts = 0
  pickupPromptState = nil
end

local DEFAULT_CONFIG = {
  id = "skeletonCoastMiningCompany",
  label = "Mining Company",
  sitesFile = "miningTruck.sites.json",
  officeSpot = "miningOffice",
  truckSpawnSpot = "miningTruckSpawn",
  pickupSpots = {"miningPickup1", "miningPickup2", "miningPickup3"},
  dropOffArea = "miningDropOff",
  organizationId = "skeletonCoastMiningCompany",
  vehicle = { model = "dumptruck", config = "standard", bedSettings = "dumptruck", licenseText = "HT-55" },
  material = { model = "rock_pile", config = "default", count = 1, tons = 100 },
  loader = { model = "wl40", config = "arm_bucket", licenseText = "WL-40", pickupOffset = {0, -5, 0.25}, lookAtMaterial = true },
  economy = { payPerRock = 350, payPerTon = 20, diamondChance = 0.12, diamondBonus = 4500, repairCost = 750 },
  detection = { officeRadius = 8, pickupRadius = 10, dropoffVehicleRadius = 14, minDeliveryRatio = 0.005, bedRouteRatio = 0.02, nodeStep = 10, processNodeStep = 1, dropoffPadding = {1.0, 1.0, 0.75} },
  autoLoad = { enabled = true, dropHeight = 1.0, spacing = 1.25, offsetSide = 0, offsetForward = 0, offsetUp = 0 },
  bedSettings = {
    dumptruck = { offsetBack = 3.1, offsetSide = 0, length = 5.8, width = 3.2, floorHeight = 1.05, loadHeight = 3.0 },
    us_semi = { offsetBack = 3.0, offsetSide = -0.45, length = 6.0, width = 2.4, floorHeight = 0.3, loadHeight = 3.5 }
  },
  dropOffAreaFallback = {
    position = {2741.2981, 5374.80664, 74.6072845},
    rotationMatrix = {0.759369135, -0.650660038, 0, 0.650660038, 0.759369135, 0, 0, 0, 1},
    scale = {2.46868801, 4.36005211, 2.06645441}
  }
}

local function deepcopyTable(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopyTable(v) end
  return out
end

local function mergeInto(base, extra)
  if type(extra) ~= "table" then return base end
  for k, v in pairs(extra) do
    if type(v) == "table" and type(base[k]) == "table" and #v == 0 then
      mergeInto(base[k], v)
    else
      base[k] = deepcopyTable(v)
    end
  end
  return base
end

local function cargo()
  return extensions.gameplay_physicalCargo or gameplay_physicalCargo
end

local function toVec3(v)
  local c = cargo()
  return c and c.toVec3 and c.toVec3(v) or vec3(v[1] or 0, v[2] or 0, v[3] or 0)
end

local function ensureSaveDir(savePath)
  local dirPath = savePath .. SAVE_DIR
  if not FS:directoryExists(dirPath) then FS:directoryCreate(dirPath) end
end

local function savePayload()
  if not state.active then
    return {
      active = false,
      phase = "idle",
      currentPickupIndex = 0,
      deliveredThisRun = 0,
      deliveriesCompleted = 0,
      oreDelivered = 0,
      diamondsFound = 0,
      grossEarnings = 0,
      repairCosts = 0
    }
  end

  return {
    active = true,
    phase = state.phase,
    currentPickupIndex = state.currentPickupIndex,
    deliveredThisRun = state.deliveredThisRun,
    deliveriesCompleted = state.deliveriesCompleted,
    oreDelivered = state.oreDelivered,
    diamondsFound = state.diamondsFound,
    grossEarnings = state.grossEarnings,
    repairCosts = state.repairCosts
  }
end

local function saveState()
  if not career_saveSystem or not career_saveSystem.getCurrentProfile then return end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then return end
  ensureSaveDir(savePath)
  career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_FILE, savePayload(), true)
end

local function saveStateToPath(savePath)
  if not savePath or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return end
  ensureSaveDir(savePath)
  career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_FILE, savePayload(), true)
end

local function loadSavedState()
  if not career_saveSystem or not career_saveSystem.getCurrentProfile then return end
  local _, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then return end
  local data = jsonReadFile(savePath .. SAVE_FILE)
  if type(data) ~= "table" or data.active ~= true then
    state.active = false
    resetShiftProgress()
    return
  end
  state.active = true
  state.phase = data.phase or "toPickup"
  state.currentPickupIndex = tonumber(data.currentPickupIndex) or 0
  state.deliveredThisRun = tonumber(data.deliveredThisRun) or 0
  state.deliveriesCompleted = tonumber(data.deliveriesCompleted) or 0
  state.oreDelivered = tonumber(data.oreDelivered) or 0
  state.diamondsFound = tonumber(data.diamondsFound) or 0
  state.grossEarnings = tonumber(data.grossEarnings) or 0
  state.repairCosts = tonumber(data.repairCosts) or 0
  state.propIds = {}
  state.truckId = nil
  state.inventoryId = nil
  state.loaderId = nil
end

local function clearSavedState()
  state.active = false
  saveState()
end

local function currentLevel()
  return getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
end

local function loadConfig(force)
  local level = currentLevel()
  if not level then
    config = nil
    sites = nil
    loadedLevel = nil
    configChecked = false
    sitesChecked = false
    return nil
  end
  if not force and configChecked and loadedLevel == level then return config end

  config = nil
  sites = nil
  loadedLevel = level
  configChecked = true
  sitesChecked = false

  local files = FS:findFiles("/levels/" .. level .. "/", "*.miningHaul.json", -1, true, false)
  local mergedConfig = deepcopyTable(DEFAULT_CONFIG)
  local foundValidConfig = false
  if type(files) == "table" then
    for _, file in ipairs(files) do
      local data = jsonReadFile(file)
      if type(data) == "table" then
        mergeInto(mergedConfig, data)
        foundValidConfig = true
      else
        log("W", "miningHaul", "Ignoring invalid mining config: " .. tostring(file))
      end
    end
  end
  if not foundValidConfig then return nil end

  config = mergedConfig
  return config
end

local function loadSites(force)
  if not config then loadConfig() end
  if not config then return nil end
  local level = currentLevel()
  if not level then return nil end
  if not force and sitesChecked and loadedLevel == level then return sites end

  sites = nil
  sitesChecked = true
  local file = "/levels/" .. level .. "/" .. (config.sitesFile or "miningTruck.sites.json")
  local loadedSites = jsonReadFile(file)
  if type(loadedSites) ~= "table" or type(loadedSites.parkingSpots) ~= "table" then
    log("W", "miningHaul", "Mining disabled; missing or invalid sites file: " .. tostring(file))
    return nil
  end

  sites = loadedSites
  return sites
end

local function ensureAvailable(force)
  loadConfig(force == true)
  if config then loadSites(force == true) end
  return config ~= nil and sites ~= nil
end

local function findSpot(name)
  if not sites then loadSites() end
  if not sites or not sites.parkingSpots then return nil end
  for _, spot in ipairs(sites.parkingSpots) do
    if spot.name == name then return spot end
  end
  return nil
end

local function spotPos(name)
  local spot = findSpot(name)
  return spot and spot.pos and toVec3(spot.pos) or nil
end

local function spotRot(name)
  local spot = findSpot(name)
  local c = cargo()
  if spot and spot.rot and c and c.toQuat then return c.toQuat(spot.rot) end
  return quat(0, 0, 0, 1)
end

local function playerVehicle()
  return be and be:getPlayerVehicle(0) or nil
end

local function isConfiguredTruck(veh)
  if not veh or not veh.getJBeamFilename then return false end
  local ok, model = pcall(function() return veh:getJBeamFilename() end)
  local expected = config and config.vehicle and config.vehicle.model or DEFAULT_CONFIG.vehicle.model
  return ok and model == expected
end

local function playerPos()
  local veh = playerVehicle()
  return veh and veh:getPosition() or nil
end

local function distTo(pos)
  local p = playerPos()
  return (p and pos) and p:distance(pos) or math.huge
end

local function isNearSpot(name, radius)
  local pos = spotPos(name)
  return pos and distTo(pos) <= (radius or 8)
end

local function getBedSettings()
  local key = config and config.vehicle and config.vehicle.bedSettings or "dumptruck"
  return config and config.bedSettings and config.bedSettings[key] or DEFAULT_CONFIG.bedSettings.dumptruck
end

local function tableOffset(t, fallback)
  t = type(t) == "table" and t or fallback
  return vec3(tonumber(t[1] or t.x) or 0, tonumber(t[2] or t.y) or 0, tonumber(t[3] or t.z) or 0)
end

local function spotYaw(name)
  local spot = findSpot(name)
  local rot = spot and spot.rot
  if not rot then return 0 end
  local z = tonumber(rot[3] or rot.z) or 0
  local w = tonumber(rot[4] or rot.w) or 1
  return 2 * math.atan2(z, w)
end

local function spotLocalToWorld(name, offset)
  local base = spotPos(name)
  if not base then return nil end
  local yaw = spotYaw(name)
  local right = vec3(math.cos(yaw), -math.sin(yaw), 0)
  local forward = vec3(math.sin(yaw), math.cos(yaw), 0)
  return base + (right * offset.x) + (forward * offset.y) + vec3(0, 0, offset.z)
end

local function getTruckObj()
  if state.truckId then
    local obj = be:getObjectByID(state.truckId)
    if obj then return obj end
    return nil
  end
  local veh = playerVehicle()
  return isConfiguredTruck(veh) and veh or nil
end

local function truckDistTo(pos)
  local truck = getTruckObj()
  return (truck and pos) and truck:getPosition():distance(pos) or math.huge
end

local function isTruckNearSpot(name, radius)
  local pos = spotPos(name)
  return pos and truckDistTo(pos) <= (radius or 8)
end

local function clearProps()
  if cargo() then cargo().deleteProps(state.propIds) end
  state.propIds = {}
end

local function pruneDeadProps()
  local live = {}
  for _, id in ipairs(state.propIds or {}) do
    if id and be:getObjectByID(id) then table.insert(live, id) end
  end
  state.propIds = live
  return #live
end

local function clearLoader()
  if state.loaderId then
    local obj = be:getObjectByID(state.loaderId)
    if obj then obj:delete() end
  end
  state.loaderId = nil
end

local function clearPickupResources()
  clearProps()
  clearLoader()
end

local function setMarker(pos, clearOnReach)
  if not pos then return false end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = clearOnReach == true })
  end
  return true
end

local function clearMarker()
  if core_groundMarkers and core_groundMarkers.setPath then core_groundMarkers.setPath(nil) end
end

local function currentPickupName()
  local pickups = config and config.pickupSpots or DEFAULT_CONFIG.pickupSpots
  if #pickups == 0 then return nil end
  local idx = state.currentPickupIndex
  if idx < 1 or idx > #pickups then idx = 1 end
  return pickups[idx]
end

local function chooseNextPickup()
  local pickups = config and config.pickupSpots or DEFAULT_CONFIG.pickupSpots
  if #pickups == 0 then return nil end
  if #pickups == 1 then
    state.currentPickupIndex = 1
  else
    local previousIndex = state.currentPickupIndex
    local nextIndex = previousIndex
    for _ = 1, 5 do
      nextIndex = math.random(1, #pickups)
      if nextIndex ~= previousIndex then break end
    end
    if nextIndex == previousIndex then
      nextIndex = (previousIndex % #pickups) + 1
    end
    state.currentPickupIndex = nextIndex
  end
  return currentPickupName()
end

local function spawnPickupResources()
  local pickupName = currentPickupName()
  local c = cargo()
  if not pickupName or not c then return false end
  clearPickupResources()

  local mat = config.material or DEFAULT_CONFIG.material
  local rockOffset = tableOffset(mat.pickupOffset, {0, 0, 0.25})
  local rockPos = spotLocalToWorld(pickupName, rockOffset)
  if not rockPos then return false end
  local rockId = c.spawnProp(mat.model or "rock_pile", mat.config or "default", rockPos, spotRot(pickupName), { cling = true, safeSpawn = true })
  if rockId then table.insert(state.propIds, rockId) end

  local loaderCfg = config.loader or DEFAULT_CONFIG.loader
  local loaderOffset = tableOffset(loaderCfg.pickupOffset, DEFAULT_CONFIG.loader.pickupOffset)
  local loaderPos = spotLocalToWorld(pickupName, loaderOffset)
  if loaderPos then
    local loaderRot = spotRot(pickupName)
    if loaderCfg.lookAtMaterial ~= false and rockPos and quatFromDir then
      local dir = rockPos - loaderPos
      if dir:length() > 0.1 then loaderRot = quatFromDir(dir:normalized(), vec3(0, 0, 1)) end
    end
    state.loaderId = c.spawnProp(loaderCfg.model or "wl40", loaderCfg.config or "arm_bucket", loaderPos, loaderRot, { cling = true, safeSpawn = true, licenseText = loaderCfg.licenseText or "WL-40" })
  end

  return #state.propIds > 0
end

local function showUi(mode, payload)
  lastUiMode = mode
  if guihooks and guihooks.trigger then
    payload = payload or {}
    payload.visible = true
    payload.mode = mode
    payload.active = state.active
    payload.phase = state.phase
    payload.label = config and config.label or "Mining Company"
    if payload.oreDelivered == nil then payload.oreDelivered = state.oreDelivered end
    if payload.deliveriesCompleted == nil then payload.deliveriesCompleted = state.deliveriesCompleted end
    if payload.diamondsFound == nil then payload.diamondsFound = state.diamondsFound end
    if payload.repairCosts == nil then payload.repairCosts = state.repairCosts end
    if payload.grossEarnings == nil then payload.grossEarnings = state.grossEarnings end
    if payload.netEarnings == nil then payload.netEarnings = math.max(0, state.grossEarnings - state.repairCosts) end
    guihooks.trigger("MiningHaulUi", payload)
  end
end

local function hideUi()
  lastUiMode = nil
  if guihooks and guihooks.trigger then guihooks.trigger("MiningHaulUi", { visible = false }) end
end

local deliveredLoadRatio
local deliveredTonsFromRatio
local isTruckAtDropoff
local canAutoLoadTruck

local function hudPayload(extra)
  local p = extra or {}
  p.pickupName = currentPickupName()
  p.target = state.phase == "toDropoff" and "Processing Facility" or "Excavation Zone"
  p.deliveredThisRun = state.deliveredThisRun
  p.totalProps = #state.propIds
  p.canEnd = state.active
  local dropoffRatio = deliveredLoadRatio and deliveredLoadRatio() or 0
  p.deliveredTons = deliveredTonsFromRatio and deliveredTonsFromRatio(dropoffRatio) or 0
  p.canProcess = state.active
  p.canLoad = canAutoLoadTruck and canAutoLoadTruck() or false
  if state.phase == "toPickup" then
    local pickupName = currentPickupName()
    p.atPickup = pickupName and isTruckNearSpot(pickupName, config.detection.pickupRadius or 10) or false
    if dropoffRatio >= ((config.detection and config.detection.minDeliveryRatio) or 0.005) then
      p.target = "Ready to Process"
    else
      p.target = p.atPickup and "Load with WL-40" or "Excavation Zone"
    end
  elseif state.phase == "toDropoff" then
    if dropoffRatio >= ((config.detection and config.detection.minDeliveryRatio) or 0.005) then
      p.target = "Ready to Process"
    elseif isTruckAtDropoff() then
      p.target = "Dump Ore in Zone"
    end
  end
  return p
end

local function payDelivery(amount)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return end
  local skillRewards = require("gameplay/jobSkillRewards")
  local operatorLevel = skillRewards.getSkillLevel("careerSkills-operator", {"careerSkills-operator", "operator"})
  local baseAmount = amount
  amount = math.floor(baseAmount * skillRewards.getOperatorMoneyBonusMultiplier(3, operatorLevel) + 0.5)
  local operatorXp = math.max(1, math.floor(baseAmount / 10))
  if career_modules_payment and career_modules_payment.reward then
    career_modules_payment.reward({
      money = { amount = amount, canBeNegative = false },
      ["careerSkills-operator"] = {amount = operatorXp}
    }, {
      label = "Mining Company ore delivery",
      tags = {"gameplay", "miningHaul", "delivery"}
    })
  elseif career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({money = amount, ["careerSkills-operator"] = operatorXp},
      {label = "Mining Company ore delivery", tags = {"gameplay", "miningHaul"}})
  end
  if Engine and Engine.Audio and Engine.Audio.playOnce then
    Engine.Audio.playOnce("AudioGui", "event:>UI>Career>Buy_01")
  end
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
end

local function registerLoaner(vehId)
  if not career_modules_inventory or not career_modules_inventory.addVehicle then return nil end
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, { owned = false })
  local inv = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()
  local vehInfo = inv and inventoryId and inv[inventoryId]
  if vehInfo then
    vehInfo.owningOrganization = config.organizationId
    vehInfo.loanType = "work"
  end
  return inventoryId
end

local function returnLoaner()
  local inventoryId = state.inventoryId
  local truckId = state.truckId
  state.truckId = nil
  state.inventoryId = nil
  if inventoryId and career_modules_inventory and career_modules_inventory.removeVehicle then
    if career_modules_inventory.updatePartConditions and career_modules_inventory.getVehicleIdFromInventoryId and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
      career_modules_inventory.updatePartConditions(nil, inventoryId, function()
        career_modules_inventory.removeVehicle(inventoryId)
      end)
    else
      career_modules_inventory.removeVehicle(inventoryId)
    end
  elseif truckId then
    local obj = be:getObjectByID(truckId)
    if obj then obj:delete() end
  end
end

local function spawnLoaner()
  local spawnName = config.truckSpawnSpot or DEFAULT_CONFIG.truckSpawnSpot
  local pos = spotPos(spawnName)
  if not pos then return false end
  local vehCfg = config.vehicle or DEFAULT_CONFIG.vehicle
  local obj = core_vehicles.spawnNewVehicle(vehCfg.model or "dumptruck", {
    pos = pos,
    rot = spotRot(spawnName),
    config = vehCfg.config or "standard",
    licenseText = vehCfg.licenseText or "HT-55",
    autoEnterVehicle = false
  })
  if not obj then return false end
  state.truckId = obj:getID()
  state.inventoryId = registerLoaner(state.truckId)
  if core_vehicleBridge and core_vehicleBridge.executeAction then
    core_vehicleBridge.executeAction(obj, "initPartConditions", {}, 0, 1, 1)
  end
  return true
end

local function getDropOffBox()
  local areaName = config.dropOffArea or DEFAULT_CONFIG.dropOffArea
  local areaObj = scenetree and scenetree.findObject(areaName) or nil
  local c = cargo()
  local box = c and c.makeBoxFromGameplayArea(areaObj, config.dropOffAreaFallback or DEFAULT_CONFIG.dropOffAreaFallback) or nil
  if box then
    local padding = tableOffset(config.detection and config.detection.dropoffPadding, DEFAULT_CONFIG.detection.dropoffPadding)
    box.halfWidth = box.halfWidth + math.max(0, padding.x)
    box.halfLength = box.halfLength + math.max(0, padding.y)
    box.halfHeight = box.halfHeight + math.max(0, padding.z)
  end
  return box
end

local function dropOffTargetPos()
  return (config.dropOffAreaFallback and toVec3(config.dropOffAreaFallback.position)) or playerPos()
end

deliveredLoadRatio = function()
  local c = cargo()
  local box = getDropOffBox()
  if not c or not box then return 0 end
  local nodeStep = (config.detection and config.detection.processNodeStep) or 1
  local totalRatio = 0
  pruneDeadProps()
  for _, id in ipairs(state.propIds) do
    totalRatio = totalRatio + c.getLoadRatioInBox(id, box, nodeStep)
  end
  return totalRatio
end

deliveredTonsFromRatio = function(ratio)
  local mat = config.material or DEFAULT_CONFIG.material
  local tons = math.max(1, tonumber(mat.tons) or 100)
  ratio = tonumber(ratio) or 0
  if ratio <= 0 then return 0 end
  return math.max(1, math.floor(ratio * tons + 0.5))
end

isTruckAtDropoff = function()
  local box = getDropOffBox()
  local truck = getTruckObj()
  if box and truck and cargo().isPointInBox(truck:getPosition(), box) then return true end
  local fallbackPos = config.dropOffAreaFallback and toVec3(config.dropOffAreaFallback.position)
  return fallbackPos and distTo(fallbackPos) <= ((config.detection and config.detection.dropoffVehicleRadius) or 14)
end

local function bedLoadRatio()
  local truck = getTruckObj()
  local c = cargo()
  if not truck or not c then return 0 end
  local totalRatio = 0
  pruneDeadProps()
  for _, id in ipairs(state.propIds) do
    totalRatio = totalRatio + c.getBedLoadRatio(id, truck, getBedSettings(), config.detection.nodeStep)
  end
  return totalRatio
end

canAutoLoadTruck = function()
  if not state.active or state.phase ~= "toPickup" then return false end
  if config and config.autoLoad and config.autoLoad.enabled == false then return false end
  local truck = getTruckObj()
  if not truck then return false end
  local pickupName = currentPickupName()
  return pickupName and isTruckNearSpot(pickupName, config.detection.pickupRadius or 10) or false
end

local function autoLoadOffsets(count, spacing)
  local offsets = {}
  count = math.max(1, math.floor(tonumber(count) or 1))
  spacing = math.max(0.25, tonumber(spacing) or 1.25)
  local columns = math.max(1, math.ceil(math.sqrt(count)))
  local rows = math.max(1, math.ceil(count / columns))
  for i = 1, count do
    local col = (i - 1) % columns
    local row = math.floor((i - 1) / columns)
    table.insert(offsets, vec3((col - (columns - 1) * 0.5) * spacing, (row - (rows - 1) * 0.5) * spacing, 0))
  end
  return offsets
end

local function updateDeliveryPrompt()
  if state.phase ~= "toDropoff" then return end
  showUi("hud", hudPayload())
end

local function resetShiftFields()
  resetShiftProgress()
end

function M.startShift()
  if state.active then return false end
  if not ensureAvailable() then return false end
  resetShiftFields()
  state.active = true
  if not spawnLoaner() then
    state.active = false
    ui_message("Mining Company could not spawn the HT-55 loaner.", 5, "Mining Company")
    return false
  end
  chooseNextPickup()
  state.phase = "toPickup"
  spawnPickupResources()
  setMarker(spotPos(currentPickupName()), false)
  saveState()
  showUi("hud", hudPayload({ notice = "Shift started" }))
  return true
end

function M.endShift()
  if not state.active then return false end
  local summary = {
    oreDelivered = state.oreDelivered,
    deliveriesCompleted = state.deliveriesCompleted,
    diamondsFound = state.diamondsFound,
    repairCosts = state.repairCosts,
    grossEarnings = state.grossEarnings,
    netEarnings = math.max(0, state.grossEarnings - state.repairCosts)
  }
  clearPickupResources()
  returnLoaner()
  clearMarker()
  state.active = false
  resetShiftFields()
  clearSavedState()
  showUi("summary", summary)
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  return true
end

function M.repairTruck()
  if not state.active then return false end
  local truck = getTruckObj()
  if not truck then return false end
  state.truckId = truck:getID()
  truck:queueLuaCommand("extensions.load('individualRepair'); if individualRepair then individualRepair.reset(); end; if recovery then recovery.recoverInPlace(); end")
  if core_vehicleBridge and core_vehicleBridge.executeAction then
    core_vehicleBridge.executeAction(truck, "initPartConditions", {}, 0, 1, 1)
  end
  local cost = math.max(0, math.floor(tonumber(config.economy.repairCost) or 750))
  state.repairCosts = state.repairCosts + cost
  saveState()
  showUi("office", { notice = "HT-55 repaired", repairCost = cost })
  return true
end

function M.loadTruck()
  if not canAutoLoadTruck() then
    showUi("hud", hudPayload({ notice = "Park the HT-55 at the excavation zone" }))
    return false
  end

  local c = cargo()
  local truck = getTruckObj()
  local bed = c and c.makeBedData and c.makeBedData(truck, getBedSettings()) or nil
  if not c or not truck or not bed then
    showUi("hud", hudPayload({ notice = "Could not find the HT-55 bed" }))
    return false
  end

  clearPickupResources()
  local mat = config.material or DEFAULT_CONFIG.material
  local autoLoadCfg = config.autoLoad or DEFAULT_CONFIG.autoLoad
  local count = math.max(1, math.floor(tonumber(mat.count) or 1))
  local dropHeight = math.max(0, tonumber(autoLoadCfg.dropHeight) or 1.0)
  local offsetSide = tonumber(autoLoadCfg.offsetSide) or 0
  local offsetForward = tonumber(autoLoadCfg.offsetForward) or 0
  local offsetUp = tonumber(autoLoadCfg.offsetUp) or 0
  local spawned = 0
  local rot = quat(0, 0, 0, 1)
  if quatFromDir then
    rot = quatFromDir(truck:getDirectionVector():normalized(), truck:getDirectionVectorUp():normalized())
  end

  for _, offset in ipairs(autoLoadOffsets(count, autoLoadCfg.spacing)) do
    local clampedX = math.max(-bed.halfWidth * 0.55, math.min(bed.halfWidth * 0.55, offset.x))
    local clampedY = math.max(-bed.halfLength * 0.55, math.min(bed.halfLength * 0.55, offset.y))
    local pos = bed.center + (bed.axisX * (clampedX + offsetSide)) + (bed.axisY * (clampedY + offsetForward)) + (bed.axisZ * (bed.halfHeight + dropHeight + offsetUp))
    local rockId = c.spawnProp(mat.model or "rock_pile", mat.config or "default", pos, rot, { cling = false, safeSpawn = false })
    if rockId then
      table.insert(state.propIds, rockId)
      spawned = spawned + 1
    end
  end

  if spawned <= 0 then
    showUi("hud", hudPayload({ notice = "Could not load ore" }))
    return false
  end

  state.phase = "toDropoff"
  pickupPromptState = nil
  state.deliveredThisRun = 0
  state.truckId = truck:getID()
  setMarker(dropOffTargetPos(), false)
  saveState()
  showUi("hud", hudPayload({ notice = "Ore loaded into HT-55" }))
  return true
end

function M.closeUi()
  if lastUiMode == "summary" and career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  hideUi()
end

function M.showOffice()
  if state.active then
    showUi("office", { canRepair = true, canEnd = true })
  else
    showUi("intro", {
      title = "HT-55 Driver Program",
      body = "The Mining Company is looking for temporary drivers to move ore from active excavation zones to the processing facility."
    })
  end
end

function M.dismissResult()
  if state.active then showUi("hud", hudPayload()) else hideUi() end
end

function M.processOre()
  if not state.active then return false end
  local ratio = deliveredLoadRatio and deliveredLoadRatio() or 0
  if ratio < ((config.detection and config.detection.minDeliveryRatio) or 0.005) then
    local notice = pruneDeadProps() > 0 and "Tracked ore is not in the hopper" or "No tracked ore remains"
    showUi("hud", hudPayload({ notice = notice }))
    return false
  end

  local deliveredTons = deliveredTonsFromRatio(ratio)
  local payPerTon = tonumber(config.economy.payPerTon) or tonumber(config.economy.payPerRock) or 350
  local pay = math.max(0, math.floor(deliveredTons * payPerTon + 0.5))
  local diamond = false
  local diamondBonus = 0
  if deliveredTons > 0 and math.random() < (config.economy.diamondChance or 0.12) then
    diamond = true
    diamondBonus = config.economy.diamondBonus or 4500
    state.diamondsFound = state.diamondsFound + 1
  end

  local totalPay = pay + diamondBonus
  state.oreDelivered = state.oreDelivered + deliveredTons
  state.deliveriesCompleted = state.deliveriesCompleted + 1
  state.grossEarnings = state.grossEarnings + totalPay
  clearPickupResources()
  chooseNextPickup()
  state.phase = "toPickup"
  state.deliveredThisRun = 0
  pickupPromptState = nil
  spawnPickupResources()
  saveState()
  payDelivery(totalPay)
  setMarker(spotPos(currentPickupName()), false)
  local notice = tostring(deliveredTons) .. " tons processed"
  if diamond then notice = notice .. " + diamond bonus" end
  showUi("hud", hudPayload({ notice = notice }))
  return true
end

local function handlePickup()
  local pickupName = currentPickupName()
  if not pickupName or state.phase ~= "toPickup" then return end
  if #state.propIds == 0 then spawnPickupResources() end
  if bedLoadRatio() >= ((config.detection and config.detection.bedRouteRatio) or 0.02) then
    state.phase = "toDropoff"
    pickupPromptState = nil
    state.deliveredThisRun = 0
    setMarker(dropOffTargetPos(), false)
    saveState()
    showUi("hud", hudPayload({ notice = "Ore detected in bed" }))
    return
  end
  local promptState = "route"
  if isTruckNearSpot(pickupName, config.detection.pickupRadius or 10) then
    promptState = "loading"
  end
  if promptState ~= pickupPromptState then
    pickupPromptState = promptState
    showUi("hud", hudPayload())
  end
end

local function handleOfficePrompt()
  local nearOffice = isNearSpot(config.officeSpot or DEFAULT_CONFIG.officeSpot, config.detection.officeRadius or 8)
  if nearOffice and lastUiMode ~= "intro" and lastUiMode ~= "office" and lastUiMode ~= "summary" then
    M.showOffice()
  elseif not nearOffice and (lastUiMode == "intro" or lastUiMode == "office") then
    hideUi()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not ensureAvailable() then return end
  local dt = dtSim or dtReal or dtRaw or 0
  checkTimer = checkTimer + dt
  uiTimer = uiTimer + dt
  if checkTimer >= 0.2 then
    checkTimer = 0
    handleOfficePrompt()
    if state.active then
      if not state.truckId then
        local veh = playerVehicle()
        if isConfiguredTruck(veh) then state.truckId = veh:getID() end
      end
      if state.phase == "toPickup" then
        handlePickup()
      elseif state.phase == "toDropoff" then
        updateDeliveryPrompt()
      end
    end
  end
  if state.active and uiTimer >= 0.75 and (lastUiMode == "hud" or not lastUiMode) then
    uiTimer = 0
    showUi("hud", hudPayload())
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  if not ensureAvailable() or levelIdentifier ~= currentLevel() then return end
  local officePos = spotPos(config.officeSpot or DEFAULT_CONFIG.officeSpot)
  if not officePos then return end
  local radius = (config.detection and config.detection.officeRadius) or DEFAULT_CONFIG.detection.officeRadius
  local label = config.label or "Mining Company"
  table.insert(elements, {
    id = "miningHaulOffice",
    data = {
      type = "miningHaul",
      pos = officePos,
      icon = "poi_pickup_round",
      name = label,
      description = "Start or end an HT-55 hauling shift."
    },
    markerInfo = {
      inspectVehicleMarker = {
        pos = officePos,
        radius = radius,
        vehicleHeight = 4
      },
      bigmapMarker = {
        pos = officePos,
        icon = "poi_pickup_round",
        name = label,
        description = "Start or end an HT-55 hauling shift.",
        cardIcon = "boxTruck",
      },
      clusterType = "activity"
    },
    pos = officePos,
    radius = radius
  })
end

local function discardUnavailableShift()
  hideUi()
  if not state.active then return end

  clearPickupResources()
  clearMarker()
  state.active = false
  resetShiftProgress()
  saveState()
  log("W", "miningHaul", "Discarded an active mining shift because this level has no valid mining configuration")
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 then
    local available = ensureAvailable(true)
    loadSavedState()
    if not available then
      discardUnavailableShift()
      return
    end
    if state.active then
      state.phase = state.phase == "toDropoff" and "toPickup" or state.phase
      clearPickupResources()
      spawnPickupResources()
      setMarker(spotPos(currentPickupName()) or spotPos(config.officeSpot), false)
    end
  end
end

local function onExtensionLoaded()
  math.randomseed(os.time())
  local available = ensureAvailable(true)
  loadSavedState()
  -- Extensions can be loaded at the main menu before a level exists. Preserve
  -- a saved shift until a real world is ready and can be checked for support.
  if not available and currentLevel() then discardUnavailableShift() end
end

local function onSaveCurrentProfile(currentSavePath)
  saveStateToPath(currentSavePath)
end

M.onUpdate = onUpdate
M.isAvailable = function() return ensureAvailable() end
M.onWorldReadyState = onWorldReadyState
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
