-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")
local buttonInstance = buttonModule.create()
local actionButtonsByPoiId = {}

local function canSetRoute()
  if career_modules_testDrive and career_modules_testDrive.isActive() then
    return false
  end
  return true
end

local function getOrCreateSetRouteButton(poiId)
  actionButtonsByPoiId[poiId] = actionButtonsByPoiId[poiId] or {}
  local cached = actionButtonsByPoiId[poiId].setRoute
  if cached then return cached end

  local meta = buttonInstance.addButton(function()
    if freeroam_bigMapMode and freeroam_bigMapMode.navigateToMission then
      freeroam_bigMapMode.navigateToMission(poiId)
    end
    return true
  end, {
    label = _tr("ui.pause.nearbyActivities.action.setRoute"),
    action = "setRoute",
    poiId = poiId,
  })
  actionButtonsByPoiId[poiId].setRoute = meta
  return meta
end

local function getOrCreateViewButton(poiId)
  actionButtonsByPoiId[poiId] = actionButtonsByPoiId[poiId] or {}
  local cached = actionButtonsByPoiId[poiId].view
  if cached then return cached end

  local meta = buttonInstance.addButton(function()
    log("I", "NearbyActivities", "View nearby activity " .. tostring(poiId))
    if not (freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap) then return false end
    -- autoSelectPoiId is picked up by the Vue bigmap once it has mounted, see getAndClearPendingAutoSelectPoiId
    freeroam_bigMapMode.enterBigMap({instant = true, routeTarget = "pause.bigmap", autoSelectPoiId = poiId})
    return true
  end, {
    label = _tr("ui.pause.nearbyActivities.action.view"),
    action = "view",
    poiId = poiId,
  })
  actionButtonsByPoiId[poiId].view = meta
  return meta
end

local function getActionsForPoi(poiId, isBigMapAllowed)
  local viewBtn = getOrCreateViewButton(poiId)
  local routeBtn = getOrCreateSetRouteButton(poiId)
  return {
    view = {
      buttonId = viewBtn.buttonId,
      label = viewBtn.label,
      action = viewBtn.action,
      icon = "mapWithEmitter",
      uiEvent = "ok",
      disabled = not isBigMapAllowed,
    },
    route = {
      buttonId = routeBtn.buttonId,
      label = routeBtn.label,
      action = routeBtn.action,
      icon = "routeSimple",
      uiEvent = "action_2",
      disabled = not canSetRoute(),
    },
  }
end

function M.executeNearbyActivityAction(buttonId, payload)
  if not buttonId then return false end
  return buttonInstance.executeButton(buttonId, payload)
end

-- World activities only (no garages/gas/dealerships/phone gigs).
local CAREER_ACTIVITY_POI_TYPES = {
  events = true,
  driftSpot = true,
  dragstrip = true,
  crawl = true,
  busWork = true,
  paramedicWork = true,
  policeWork = true,
  miningHaul = true,
  facilityWork = true,
}

-- Freeroam: vanilla-style activities + RLS freeroam events only.
local FREEROAM_ACTIVITY_POI_TYPES = {
  events = true,
  driftSpot = true,
  dragstrip = true,
  crawl = true,
}

local function getActivityPoiTypes()
  if career_career and career_career.isActive() then
    return CAREER_ACTIVITY_POI_TYPES
  end
  return FREEROAM_ACTIVITY_POI_TYPES
end

local function prettyPoiType(poiType)
  local names = {
    mission = "ui.pause.nearbyActivities.poiType.mission",
    spawnPoint = "ui.pause.nearbyActivities.poiType.spawnPoint",
    garage = "ui.pause.nearbyActivities.poiType.garage",
    gasStation = "ui.pause.nearbyActivities.poiType.gasStation",
    dealership = "ui.pause.nearbyActivities.poiType.dealership",
    logisticsParking = "ui.pause.nearbyActivities.poiType.logisticsParking",
    logisticsOffice = "ui.pause.nearbyActivities.poiType.logisticsOffice",
    driftSpot = "ui.pause.nearbyActivities.poiType.driftSpot",
    dragstrip = "ui.pause.nearbyActivities.poiType.dragstrip",
    crawl = "ui.pause.nearbyActivities.poiType.crawl",
    playerVehicle = "ui.pause.nearbyActivities.poiType.playerVehicle",
    events = "Events",
    busWork = "Bus Work",
    paramedicWork = "Paramedic Work",
    policeWork = "Police Work",
    miningHaul = "Mining Company",
    facilityWork = "Facility Work",
  }
  local key = names[poiType]
  if not key then
    return tostring(poiType or _tr("ui.pause.nearbyActivities.poiType.activity"))
  end
  if type(key) == "string" and key:find("^ui%.", 1) then
    return _tr(key)
  end
  return key
end

local function formatNearbyTitle(poiType, poiName)
  local typeLabel = prettyPoiType(poiType)
  local name = poiName and tostring(poiName) or ""
  if name == "" then
    return typeLabel
  end
  if typeLabel == "" or typeLabel == tostring(poiType) then
    return _tr(name)
  end
  return typeLabel .. " - " .. _tr(name)
end

local function getPlayerPos()
  if core_camera and core_camera.getPosition then
    return core_camera.getPosition()
  end
  return nil
end

local function getRawPoiById()
  local byId = {}
  if not gameplay_rawPois or not gameplay_rawPois.getRawPoiListByLevel then
    return byId
  end

  gameplay_rawPois.clear()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  local rawPois = gameplay_rawPois.getRawPoiListByLevel(levelId) or {}
  for _, poi in ipairs(rawPois) do
    if poi and poi.id then
      byId[poi.id] = poi
    end
  end
  return byId
end

local function getDistanceFromPlayer(playerPos, poi, rawPoi)
  if not playerPos then return nil end

  local pos = poi and poi.pos or nil
  local radius = (poi and poi.radius) or 0
  if (not pos) and rawPoi and rawPoi.markerInfo and rawPoi.markerInfo.bigmapMarker then
    pos = rawPoi.markerInfo.bigmapMarker.pos
    radius = rawPoi.markerInfo.bigmapMarker.radius or radius
  end
  if not pos then return nil end

  -- Accept vec3 or plain {x,y,z}/[1,2,3] tables from cached POI data.
  if type(pos) == "table" and not pos.squaredLength then
    pos = vec3(pos.x or pos[1] or 0, pos.y or pos[2] or 0, pos.z or pos[3] or 0)
  end

  return math.max(0, (pos - playerPos):length() - (radius or 0))
end

local function sortByDistance(a, b)
  if a.distanceM and b.distanceM then return a.distanceM < b.distanceM end
  if a.distanceM then return true end
  if b.distanceM then return false end
  return tostring(a.id) < tostring(b.id)
end

local function addUniqueSelection(selection, selectedIds, item)
  if not item or selectedIds[item.id] then return false end
  selectedIds[item.id] = true
  table.insert(selection, item)
  return true
end

local function getUnselectedItems(items, selectedIds)
  local remaining = {}
  for _, item in ipairs(items) do
    if not selectedIds[item.id] then
      table.insert(remaining, item)
    end
  end
  return remaining
end

local function addNearestSelections(selection, selectedIds, items, count)
  for _, item in ipairs(items) do
    if count <= 0 then return end
    if addUniqueSelection(selection, selectedIds, item) then
      count = count - 1
    end
  end
end

local function addMediumDistanceSelections(selection, selectedIds, items, count)
  local remaining = getUnselectedItems(items, selectedIds)
  if #remaining == 0 then return end

  local startIndex = math.max(1, math.floor((#remaining - count) / 2) + 1)
  for i = startIndex, #remaining do
    if count <= 0 then return end
    if addUniqueSelection(selection, selectedIds, remaining[i]) then
      count = count - 1
    end
  end
end

local function addRandomSelections(selection, selectedIds, items, count)
  local remaining = getUnselectedItems(items, selectedIds)
  while count > 0 and #remaining > 0 do
    local index = math.random(#remaining)
    if addUniqueSelection(selection, selectedIds, remaining[index]) then
      count = count - 1
    end
    table.remove(remaining, index)
  end
end

-- Always surface activities you are standing next to; sampler only fills leftover slots.
local NEAR_RADIUS_M = 250

local function selectActivityItems(items, maxItems)
  local selection = {}
  local selectedIds = {}
  local targetCount = maxItems or 6

  local near = {}
  local far = {}
  for _, item in ipairs(items) do
    if item.distanceM and item.distanceM <= NEAR_RADIUS_M then
      table.insert(near, item)
    else
      table.insert(far, item)
    end
  end
  table.sort(near, sortByDistance)
  table.sort(far, sortByDistance)

  for _, item in ipairs(near) do
    if #selection >= targetCount then break end
    addUniqueSelection(selection, selectedIds, item)
  end

  if #selection < targetCount then
    addNearestSelections(selection, selectedIds, far, math.min(2, targetCount - #selection))
    addMediumDistanceSelections(selection, selectedIds, far, math.min(2, targetCount - #selection))
    addRandomSelections(selection, selectedIds, far, targetCount - #selection)
  end

  table.sort(selection, sortByDistance)
  return selection
end

local function getNearbyActivityItems(maxItems, isBigMapAllowed)
  if not freeroam_vueBigMap or not freeroam_vueBigMap.getPoiData then
    return {}
  end

  local playerPos = getPlayerPos()
  local poiData = freeroam_vueBigMap.getPoiData() or {}
  local rawPoiById = getRawPoiById()
  local out = {}

  local activityTypes = getActivityPoiTypes()
  for poiId, poi in pairs(poiData) do
    if activityTypes[poi.type] then
      local rawPoi = rawPoiById[poiId]
      local dist = getDistanceFromPlayer(playerPos, poi, rawPoi)
      if dist then
        local rawId = poi.id or poiId
        table.insert(out, {
          id = tostring(rawId),
          title = formatNearbyTitle(poi.type, poi.name or tostring(rawId)),
          icon = poi.icon,
          description = prettyPoiType(poi.type),
          actionLabel = _tr("ui.pause.nearbyActivities.action.open"),
          poiType = poi.type,
          distanceM = dist and math.floor(dist + 0.5) or nil,
          actions = getActionsForPoi(rawId, isBigMapAllowed),
        })
      end
    end
  end

  table.sort(out, sortByDistance)
  return selectActivityItems(out, maxItems)
end

function M.getData(context)
  local mode = context and context.mode or "freeroam"
  local nearbyItems = getNearbyActivityItems(6, context and context.isBigMapAllowed)

  if #nearbyItems == 0 then
    nearbyItems = {
      {
        id = "nearby.none",
        title = _tr("ui.pause.nearbyActivities.none.title"),
        description = _tr("ui.pause.nearbyActivities.none.description"),
        actionLabel = _tr("ui.pause.nearbyActivities.none.openMap"),
      },
    }
  end

  return {
    mode = mode,
    sections = {
      {
        id = "nearbyActivities",
        title = _tr("ui.pause.nearbyActivities.sectionTitle"),
        items = nearbyItems,
      },
    },
  }
end

return M
