local M = {}

M.dependencies = {
  'career_career',
  'career_modules_roadsideServiceComputer',
}

local TRIGGER_PREFIX = "repairSpot"
local MARKER_ICON = "poi_garage_2_round"
local RAY_UP = 3
local RAY_DOWN = 40
local MIN_PAD_WIDTH = 2.0
local MIN_PAD_LENGTH = 3.5
local MIN_PAD_HEIGHT = 2.0

local opening = false
local activeTriggerName = nil

local function isCareerActive()
  return career_career and career_career.isActive and career_career.isActive()
end

local function resolveInventoryId(subjectId)
  local inventory = career_modules_inventory
  if not inventory then
    return nil
  end
  local invId = inventory.getCurrentVehicle()
  if invId then
    return invId
  end
  if subjectId then
    return inventory.getInventoryIdFromVehicleId(subjectId)
  end
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if playerVehId and playerVehId > 0 then
    return inventory.getInventoryIdFromVehicleId(playerVehId)
  end
  return nil
end

local function tryOpenService(subjectId, triggerName)
  if opening then
    return
  end
  if not isCareerActive() then
    return
  end

  if not career_modules_inventory then
    ui_message("Inventory is still loading. Try again in a moment.", 5, "Roadside Service", "info")
    return
  end

  local invId = resolveInventoryId(subjectId)
  if not invId then
    ui_message("Only owned vehicles can be serviced here.", 5, "Roadside Service", "info")
    return
  end

  opening = true
  career_modules_inventory.updatePartConditions(nil, invId, function()
    opening = false
    if not career_modules_inventory then
      return
    end
    local vehicle = career_modules_inventory.getVehicles()[invId]
    if not vehicle then
      return
    end
    
    log("I", "roadsideRepair", string.format("tryOpenService: invId=%s, trigger=%s", tostring(invId), tostring(triggerName or activeTriggerName)))
    if career_modules_roadsideServiceComputer and career_modules_roadsideServiceComputer.openMenu then
      log("I", "roadsideRepair", "Calling roadsideServiceComputer.openMenu")
      career_modules_roadsideServiceComputer.openMenu(invId, triggerName or activeTriggerName)
    else
      log("W", "roadsideRepair", "roadsideServiceComputer module not available")
      ui_message("Roadside Service is unavailable.", 5, "Roadside Service", "info")
    end
  end)
end

local function groundPosFromTrigger(obj)
  local pos = obj:getPosition()
  local start = vec3(pos.x, pos.y, pos.z + RAY_UP)
  local hit = castRayStatic(start, vec3(0, 0, -1), RAY_DOWN)
  if hit and hit < RAY_DOWN then
    return vec3(pos.x, pos.y, start.z - hit + 0.02)
  end
  return vec3(pos.x, pos.y, pos.z)
end

local function flattenAxis(axis, fallback)
  if not axis then
    return fallback
  end
  local flat = vec3(axis.x, axis.y, 0)
  if flat:length() > 0.001 then
    return flat:normalized()
  end
  return fallback
end

local function padFrameFromTrigger(obj)
  local scl = obj.getScale and obj:getScale() or nil
  local sx = math.abs((scl and scl.x) or 3)
  local sy = math.abs((scl and scl.y) or 6)
  local sz = math.abs((scl and scl.z) or 2)

  local axisX, axisY
  if obj.getTransform then
    local tf = obj:getTransform()
    if tf and tf.getColumn then
      axisX = tf:getColumn(0)
      axisY = tf:getColumn(1)
    end
  end
  if not axisY and obj.getDirectionVector then
    axisY = obj:getDirectionVector()
  end
  if not axisX and axisY and obj.getDirectionVectorUp then
    local up = obj:getDirectionVectorUp()
    if up then
      axisX = up:cross(axisY)
    end
  end

  local xFlat = flattenAxis(axisX, vec3(1, 0, 0))
  local yFlat = flattenAxis(axisY, vec3(0, 1, 0))

  local forward, width, length
  if sx >= sy then
    forward = xFlat
    width = sy
    length = sx
  else
    forward = yFlat
    width = sx
    length = sy
  end

  if forward:length() < 0.001 then
    forward = vec3(0, 1, 0)
  else
    forward = forward:normalized()
  end

  return forward, vec3(math.max(width, MIN_PAD_WIDTH), math.max(length, MIN_PAD_LENGTH), math.max(sz, MIN_PAD_HEIGHT))
end

local function collectRepairTriggerNames()
  local names = {}
  local seen = {}
  local function consider(list)
    for _, name in ipairs(list or {}) do
      if type(name) == "string" and name:find(TRIGGER_PREFIX, 1, true) and not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
  end
  if scenetree and scenetree.findClassObjects then
    consider(scenetree.findClassObjects("BeamNGTrigger"))
    consider(scenetree.findClassObjects("BeamNGEnvTrigger"))
  end
  return names
end

local function prettyServiceSpotName(triggerName)
  local base = tostring(triggerName or ""):gsub("_?repairSpot$", ""):gsub("_", " ")
  if base == "" then
    return "Roadside Service"
  end
  local titled = base:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
  return titled .. " Service"
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not isCareerActive() then
    return
  end
  for _, name in ipairs(collectRepairTriggerNames()) do
    local obj = scenetree.findObject(name)
    if obj then
      local pos = groundPosFromTrigger(obj)
      local forward, scale = padFrameFromTrigger(obj)
      local label = prettyServiceSpotName(name)
      table.insert(elements, {
        id = "roadsideService-" .. name,
        data = {
          type = "repairSpot",
          triggerName = name,
          name = label,
        },
        markerInfo = {
          parkingMarker = {
            path = "roadsideService#" .. name,
            pos = pos,
            rot = quatFromDir(forward, vec3(0, 0, 1)),
            scl = scale,
            icon = MARKER_ICON,
          },
          bigmapMarker = {
            pos = pos,
            icon = MARKER_ICON,
            name = label,
            description = "Park here to service your vehicle.",
            cardIcon = "wrench",
          },
        },
      })
    end
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "repairSpot" then
      local triggerName = elem.triggerName
      table.insert(activityData, {
        icon = MARKER_ICON,
        heading = elem.name or "Roadside Service",
        preheadings = {"Roadside Service"},
        buttonLabel = "Service your vehicle",
        buttonFun = function()
          activeTriggerName = triggerName
          tryOpenService(nil, triggerName)
        end,
        sorting = {
          type = elem.type,
          id = triggerName,
        },
      })
    end
  end
end

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.openService = tryOpenService

return M
