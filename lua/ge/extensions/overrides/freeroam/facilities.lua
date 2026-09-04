-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This module manages general locations and identifications of facilities on a map. It uses map info and sites data to return parking spots and other objects.

-- Feel free to move this module in the future, if needed.

local M = {}
local missingPreview = "/ui/modules/gameContext/noPreview.jpg"

local facilitiesByLevel = {}

local facilityTypeToListName = {
  garage = "garages",
  gasStation = "gasStations",
  dealership = "dealerships",
  computer = "computers",
  privateSeller = "privateSellers",
  deliveryProvider = "deliveryProviders",
  dragstrip = "dragstrips",
  tuningShop = "tuningShops",
  racingTeam = "racingTeams",
  businessGarage = "businessGarages"
}

local facilityTypeToUiLabelSingular = {
  garage = "ui.facilities.type.garage",
  gasStation = "ui.facilities.type.gasStation",
  dealership = "ui.facilities.type.dealership",
  computer = "ui.facilities.type.computer",
  privateSeller = "ui.facilities.type.privateSeller",
  deliveryProvider = "ui.facilities.type.deliveryProvider",
  dragstrip = "ui.facilities.type.dragstrip",
  tuningShop = "Tuning Shop",
  racingTeam = "Racing Team",
  businessGarage = "Business Garage"
}


-- helper function for checking if files exist
local function fileExistsDefault(path, fallbackPath)
  if path == nil then return fallbackPath end
  if type(path) ~= "table" then path = {path} end
  for _, p in ipairs(path) do
    if FS:fileExists(p) then return p end
  end
  return fallbackPath
end

-- Previews that are only a filename live under /facilities/images/.
-- Paths with their own folder (e.g. previews/ next to the json) stay relative to fileDir.
local function resolveFacilityPreview(raw, fileDir, levelDir, facilitiesBaseDir)
  if not raw or raw == '' then return raw end
  if raw:sub(1, 1) == '/' then
    return fileExistsDefault({raw}, missingPreview)
  end
  local candidates = {}
  local sharedName = nil
  if not raw:find("/", 1, true) then
    sharedName = raw
  end
  if sharedName then
    table.insert(candidates, facilitiesBaseDir .. "images/" .. sharedName)
  end
  if raw:sub(1, 7) == "images/" then
    table.insert(candidates, facilitiesBaseDir .. raw)
  end
  table.insert(candidates, fileDir .. raw)
  table.insert(candidates, levelDir .. raw)
  return fileExistsDefault(candidates, missingPreview)
end


-- parses and sanitizes a singular facility entry and adds it to the facilitiesTypeList.
local function parseFacility(f, facilityType, facilitiesTypeList, levelDir, fileDir, fileName, index, facilitiesBaseDir)
  -- sanitize
  f.id = f.id or (string.format("%s%s-%s-%d",fileDir, fileName, facilityType, index))
  f.type = facilityType
  f.preview = f.preview or 'defaultFacility.jpg'
  f.preview = resolveFacilityPreview(f.preview, fileDir, levelDir, facilitiesBaseDir)
  f.sitesFile = f.sitesFile or "facilities.sites.json"
  if type(f.sitesFile) == "table" then
    for index, file in ipairs(f.sitesFile) do
      f.sitesFile[index] = fileExistsDefault({fileDir..file, levelDir.. file}, levelDir.."facilities.sites.json")
    end
  else
    f.sitesFile = fileExistsDefault({fileDir..f.sitesFile, levelDir.. f.sitesFile}, levelDir.."facilities.sites.json")
  end

  f.zoneNames = f.zoneNames or {}
  f.parkingSpotNames = f.parkingSpotNames or {}
  table.insert(facilitiesTypeList, f)
end

-- this funcion can parse *.facilities.json, but also the info.json in a level folder.
local function parseFacilitiyFile(file, facilities, levelDir, facilitiesBaseDir)
  if not FS:fileExists(file) then return end
  local fileDir, fn, _ = path.split(file, true)
  local data = jsonReadFile(file)
  for type, listKey in pairs(facilityTypeToListName) do
    for i, f in ipairs(data[listKey] or {}) do
      parseFacility(f, type, facilities[listKey], levelDir, fileDir, fn, i, facilitiesBaseDir)
    end
  end
end

local function getFacilities(levelName)
  if not levelName or levelName == '' then
    log("E","","Tried to get facilities without level!")
    return
  end
  if not facilitiesByLevel[levelName] then

    -- init facility table
    facilitiesByLevel[levelName] = {}
    for _, listKey in pairs(facilityTypeToListName) do facilitiesByLevel[levelName][listKey] = {} end

    -- parse info.json of the level
    local levelInfo = core_levels.getLevelByName(levelName)
    if levelInfo then
      local facilitiesBaseDir = levelInfo.dir .. "/facilities/"
      parseFacilitiyFile(levelInfo.dir.."/info.json", facilitiesByLevel[levelName], levelInfo.misFilePath, facilitiesBaseDir)

      -- parse any other facility files inside the levels /facilities folder
      for _,file in ipairs(FS:findFiles(levelInfo.dir.."/facilities/", '*.facilities.json', -1, false, true)) do
        parseFacilitiyFile(file, facilitiesByLevel[levelName], levelInfo.misFilePath, facilitiesBaseDir)
      end
    end
    log("D","",string.format("Loaded facilities on level %s (%d garages, %d gasStations, %d dealerships)",levelName, #facilitiesByLevel[levelName].garages, #facilitiesByLevel[levelName].gasStations, #facilitiesByLevel[levelName].dealerships))
  end
  return facilitiesByLevel[levelName]
end

-- returns a single facility element. quiet=true skips the missing-id error
-- (owned garages from other career maps are valid and common).
local function getFacility(type, id, quiet)
  local levelName = getCurrentLevelIdentifier()
  if not levelName or levelName == '' then log("E","","Tried to get facility without level!") return end

  local facilities = getFacilities(levelName)
  local listName = facilityTypeToListName[type] or "none"
  if listName == "none" then log("E","","Tried to get facility of type " .. dumps(type)..", which is not a valid type! ("..dumps(tableKeysSorted(facilityTypeToListName))) end

  for _, f in ipairs(facilities[listName] or {}) do
    if f.id == id then
      return f
    end
  end
  if not quiet then
    log("E","","Could not find facility with id " .. dumps(id))
  end
end

local function getFacilitiesByType(type, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName or levelName == '' then log("E","","Tried to get facility without level!") return end

  local facilities = getFacilities(levelName)
  local listName = facilityTypeToListName[type] or "none"
  if listName == "none" then log("E","","Tried to get facilities of type " .. dumps(type)..", which is not a valid type! ("..dumps(tableKeysSorted(facilityTypeToListName))) end

  return facilities[listName]
end

-- POI integration
local function getZonesForFacility(facility)
  if not facility.sitesFile then log("E","","Facility has not sites file: " .. dumpsz(facility,1)) return end
  local zones = {}

  local sites = {}
  if type(facility.sitesFile) == "string" then
    table.insert(sites, gameplay_sites_sitesManager.loadSites(facility.sitesFile))
  else
    for _, sitesFile in ipairs(facility.sitesFile) do
      table.insert(sites, gameplay_sites_sitesManager.loadSites(sitesFile))
    end
  end

  for _, zoneName in ipairs(facility.zoneNames) do
    local psFound = false
    for _, sitesFromFile in ipairs(sites) do
      local zone = sitesFromFile.zones.byName[zoneName]
      if zone and not zone.missing then
        table.insert(zones, zone)
        psFound = true
        break
      end
    end
    if not psFound then
      log("W","","Missing Spot for facility" .. dumps(facility.id).."?: " .. dumps(v))
    end
  end

  if tableIsEmpty(sites) then
    log("W","","Could not find sites file for facility: " .. dumps(facility.sitesFile))
  end
  return zones
end

local function extractZoneData(facility)
  local success = false
  local zones = {}
  local pos, radius = vec3(), 5
  local zones = getZonesForFacility(facility)
  if zones then
    local aabb = {
      xMin = math.huge, xMax = -math.huge,
      yMin = math.huge, yMax = -math.huge,
      zMin = math.huge, zMax = -math.huge,
      invalid = true}
    for _, zone in ipairs(zones) do
      for i, v in ipairs(zone.vertices) do
        aabb.xMin = math.min(aabb.xMin, v.pos.x)
        aabb.xMax = math.max(aabb.xMax, v.pos.x)
        aabb.yMin = math.min(aabb.yMin, v.pos.y)
        aabb.yMax = math.max(aabb.yMax, v.pos.y)
        aabb.zMin = math.min(aabb.zMin, v.pos.z)
        aabb.zMax = math.max(aabb.zMax, v.pos.z)
        aabb.invalid = false
      end
    end
    if not aabb.invalid then
      pos = vec3((aabb.xMin + aabb.xMax)/2, (aabb.yMin + aabb.yMax)/2, (aabb.zMin + aabb.zMax)/2)
      pos.z = core_terrain.getTerrainHeight(pos) or pos.z
      radius = math.sqrt(((aabb.xMax - aabb.xMin)/2) * ((aabb.xMax - aabb.xMin)/2) + ((aabb.yMax - aabb.yMin)/2) * ((aabb.yMax - aabb.yMin)/2))
      success =true
    else
      log("E","","AABB is invalid: " .. dumps(aabb))
    end
  end
  return success, pos, radius, zones
end


local function getGarage(id) return getFacility("garage", id) end
local function getGasStation(id) return getFacility("gasStation", id) end
local function getDealership(id) return getFacility("dealership", id) end


local function getAverageDoorPositionForFacility(facility)
  local center, count = vec3(0,0,0), 0

  for _, pair in ipairs(facility.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facility " .. facility.id)
    end
  end

  if count > 0 then
    return center / count
  else
    local success, pos = extractZoneData(facility)
    if success then
      return pos
    end
    -- log("D","","Facility has no doors or zones and thus no position! " .. facility.id)
    return nil
  end
end

local function getClosestDoorPositionForFacility(facility)
  local camPos = core_camera.getPosition()
  local center = getAverageDoorPositionForFacility(facility)
  local closest = nil
  local closestDist = math.huge

  for _, pair in ipairs(facility.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      local dist = (obj:getPosition() - camPos):length()
      if dist < closestDist then
        closestDist = dist
        closest = obj:getPosition()
      end
    end
  end
  return closest
end





local function getParkingSpotsForFacility(facility)
  if not facility.sitesFile then log("E","","Facility has not sites file: " .. dumpsz(facility,1)) return end
  local spots = {}

  local sites = {}
  if type(facility.sitesFile) == "string" then
    table.insert(sites, gameplay_sites_sitesManager.loadSites(facility.sitesFile))
  else
    for _, sitesFile in ipairs(facility.sitesFile) do
      table.insert(sites, gameplay_sites_sitesManager.loadSites(sitesFile))
    end
  end
  for _, parkingSpotName in ipairs(facility.parkingSpotNames) do
    local psFound = false
    for _, sitesFromFile in ipairs(sites) do
      local spot = sitesFromFile.parkingSpots.byName[parkingSpotName]
      if spot and not spot.missing then
        table.insert(spots, spot)
        psFound = true
        break
      end
    end
    if not psFound then
      log("W","","Missing Spot for facility" .. dumps(facility.id).."?: " .. dumps(parkingSpotName))
    end
  end
  if tableIsEmpty(sites) then
    log("W","","Could not find sites file for facility: " .. dumps(facility.sitesFile))
  end
  return spots
end

local function getGaragePosRot(poi, veh)
  veh = veh or getPlayerVehicle(0)
  local garage = getGarage(poi.id) -- TODO: implement "default garage" property for level
  if not garage then return end
  local parkingSpots = getParkingSpotsForFacility(garage)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end
  return nil, nil
end

--- Racing team big-map quick travel (QOL skill: qol / quick-travel). Uses team business garage parking.
local function getRacingTeamQuickTravelPosRot(poi, veh)
  if not poi or not poi.id then
    return nil, nil
  end
  if not career_career or not career_career.isActive() then
    return nil, nil
  end
  local st = career_modules_business_businessSkillTree
  if not st or not st.getNodeProgress then
    return nil, nil
  end
  local level = tonumber(st.getNodeProgress(poi.id, "qol", "quick-travel")) or 0
  if level < 1 then
    return nil, nil
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessGaragePosRot then
    return nil, nil
  end
  -- Spot 1 avoids getBestParkingSpotForVehicleFromList (same stall risk as recovery taxi during map/UI init).
  return inv.getBusinessGaragePosRot("racingTeam", poi.id, veh, 1)
end

local function teleportToGarage(garageId, veh, resetVeh)
  local pos, rot = getGaragePosRot({id = garageId}, veh)
  if pos and rot then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, resetVeh)
    core_camera.resetCamera(0)
    extensions.hook("onTeleportedToGarage", garageId, veh)
    if core_groundMarkers.currentlyHasTarget() then
      freeroam_bigMapMode.setNavFocus(core_groundMarkers.endWP[1])
    end
  end
end
M.teleportToGarage = teleportToGarage

local facilityPoiDefaults = {
  garage = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = true,
    quickTravelPosRotFunction = getGaragePosRot,
    clusterType = 'zoneMarker',
  },
  gasStation = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'gasStationMarker',
  },
  dealership = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  computer = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  deliveryProvider = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  dragstrip = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'vehicleTrigger',
  },
  tuningShop = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  racingTeam = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
}

M.zoneMarkerFormatFacility = function(f, elements, bigMapIcon)
  local success, pos, radius, zones = extractZoneData(f)
  if success then
    if type(f.markerPos) == "table" then
      pos = vec3(f.markerPos[1] or 0, f.markerPos[2] or 0, f.markerPos[3] or 0)
    end
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},

      markerInfo = {
        zoneMarker = {zones = zones, pos = pos, radius = radius},
        bigmapMarker = { pos = pos, icon = f.icon,  name = f.name, description = f.description, thumbnail = f.preview, previews = {f.preview}, quickTravelPosRotFunction = getGaragePosRot}
      },
    }
    table.insert(elements, e)
  else
    log("E","","Could not load facility zone data! " .. dumps(data.id))
  end
end


M.walkingMarkerFormatFacility = function(f, elements)

  local center, count = vec3(0,0,0), 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facilitiy " .. f.id)
    end
  end
  if count > 0 then center = center / count end

  local maxDistSqr = 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      maxDistSqr = math.max(maxDistSqr, (obj:getPosition()-center):squaredLength() + square(pair[3] or 6))
    end
  end
  if count > 0 then
    local facilityCardIcons = {
      computer = "laptop",
      tuningShop = "wrench",
      racingTeam = "raceFlag",
      dealership = "carDealer",
      garage = "garage01",
    }
    local bigmapMarker = {
      pos = center,
      icon = f.icon or f.playModeIconName,
      name = f.name,
      description = f.description,
      thumbnail = f.preview,
      previews = {f.preview},
      cardIcon = facilityCardIcons[f.type],
    }
    if f.type == "racingTeam" and career_career and career_career.isActive() then
      local st = career_modules_business_businessSkillTree
      if st and st.getNodeProgress then
        local qtLevel = tonumber(st.getNodeProgress(f.id, "qol", "quick-travel")) or 0
        if qtLevel > 0 then
          bigmapMarker.quickTravelPosRotFunction = getRacingTeamQuickTravelPosRot
        end
      end
    end
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},
      markerInfo = {
        walkingMarker = { doors = deepcopy(f.doors), iconOffsetHeight = f.iconOffsetHeight, iconLift = f.iconLift, icon = f.playModeIconName or f.icon, pos = center, radius = math.sqrt(maxDistSqr), screens = f.screens, garageId = f.garageId or nil },
        bigmapMarker = bigmapMarker
      }
    }
    table.insert(elements, e)
  else
    log("E","","No objects found for facilitiy " .. f.id .. " ! " .. dumps(f.doors))
  end
end

M.vehicleTriggerFormatFacility = function(f, elements)
  local center, count = vec3(0,0,0), 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facilitiy " .. f.id)
    end
  end
  if count > 0 then center = center / count end

  local maxDistSqr = 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      maxDistSqr = math.max(maxDistSqr, (obj:getPosition()-center):squaredLength() + square(pair[3] or 6))
    end
  end

  if count > 0 then
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},
      markerInfo = {
        vehicleTrigger = { doors = deepcopy(f.doors), iconOffsetHeight = f.iconOffsetHeight, iconLift = f.iconLift, icon = f.playModeIconName or f.icon, pos = center, radius = math.sqrt(maxDistSqr), screens = f.screens},
        bigmapMarker = {
          pos = center,
          icon = f.icon or f.playModeIconName,
          name = f.name,
          description = f.description,
          thumbnail = f.preview,
          previews = {f.preview},
          cardIcon = f.type == "dragstrip" and "drag02" or nil,
        }
      }
    }
    table.insert(elements, e)
  else
    log("E","","No objects found for facilitiy " .. f.id .. " ! " .. dumps(f.doors))
  end
end


-- Get position for a delivery provider from its sites file (first inspect manualAccessPoint).
local function getDeliveryProviderPosition(f)
  if not f or not f.sitesFile or not f.manualAccessPoints or #f.manualAccessPoints == 0 then
    return nil
  end
  local psName = nil
  for _, ap in ipairs(f.manualAccessPoints) do
    if ap.isInspectSpot and ap.psName then
      psName = ap.psName
      break
    end
  end
  if not psName then
    psName = f.manualAccessPoints[1].psName
  end
  local paths = type(f.sitesFile) == "table" and f.sitesFile or { f.sitesFile }
  for _, path in ipairs(paths) do
    local data = jsonReadFile(path)
    if data and data.parkingSpots then
      for _, spot in ipairs(data.parkingSpots) do
        if spot.name == psName and spot.pos and #spot.pos >= 3 then
          return vec3(spot.pos[1], spot.pos[2], spot.pos[3])
        end
      end
    end
  end
  return nil
end

local function formatFacilityToRawPoi(f, elements)
  if not f then return end
  local e = M[facilityPoiDefaults[f.type].clusterType.."FormatFacility"](f, elements)
  if e then
    -- put in the default values for this facility, if the facility itself did not define it
    for key, value in pairs(facilityPoiDefaults[f.type]) do
      e[key] = f[key]
      if e[key] == nil then
        e[key] = value
      end
    end
    table.insert(elements, e)
  end
end
M.formatFacilityToRawPoi = formatFacilityToRawPoi

-- Returns a shallow copy of the facility whose `doors` only contains entries
-- that are either unlocked (skill node level > 0) or have no lock entry.
-- Returns nil when the facility has zero remaining doors.
local function filterLockedDoors(f)
  if not f or not f.doorLocks or not next(f.doorLocks) then
    return f
  end
  -- Racing team onboarding:
  -- - Before purchase: show both downstairs and upstairs markers.
  -- - After purchase: show upstairs only, until laptop is unlocked.
  if f.type == "racingTeam" and career_modules_business_businessManager then
    local mgr = career_modules_business_businessManager
    local fid = f.id
    local purchased = mgr.isPurchasedBusiness and mgr.isPurchasedBusiness("racingTeam", fid) == true
    if not purchased and mgr.getPurchasedBusinesses then
      local owned = mgr.getPurchasedBusinesses("racingTeam") or {}
      for bid, entry in pairs(owned) do
        if entry == true or type(entry) == "table" then
          if bid == fid or tostring(bid) == tostring(fid) then
            purchased = true
            break
          end
          local nb, nf = tonumber(bid), tonumber(fid)
          if nb and nf and nb == nf then
            purchased = true
            break
          end
        end
      end
    end
    local skillTree = career_modules_business_businessSkillTree
    local laptopLv = 0
    if skillTree and skillTree.getNodeProgress then
      local ok, v = pcall(skillTree.getNodeProgress, f.id, "team-operations", "laptop")
      if ok then
        laptopLv = tonumber(v) or 0
      end
    end
    local keepDownstairs = (not purchased) or laptopLv > 0
    local copy = deepcopy(f)
    copy.doors = {}
    for _, pair in ipairs(f.doors or {}) do
      local doorId = pair and pair[1]
      if doorId == "rlsRacingComputer_area1" then
        table.insert(copy.doors, pair) -- upstairs always visible
      elseif doorId == "rlsRacingComputer_area" then
        if keepDownstairs then
          table.insert(copy.doors, pair)
        end
      else
        -- Preserve any other racing-team doors with normal lock behavior.
        local lock = doorId and f.doorLocks[doorId]
        if not lock then
          table.insert(copy.doors, pair)
        else
          local lv = 0
          if skillTree and skillTree.getNodeProgress then
            local ok2, v2 = pcall(skillTree.getNodeProgress, f.id, lock.treeId, lock.nodeId)
            if ok2 then lv = tonumber(v2) or 0 end
          end
          if lv > 0 then
            table.insert(copy.doors, pair)
          end
        end
      end
    end
    if #copy.doors == 0 then
      return nil
    end
    return copy
  end
  local skillTree = career_modules_business_businessSkillTree
  local kept = {}
  for _, pair in ipairs(f.doors or {}) do
    local lock = pair and pair[1] and f.doorLocks[pair[1]]
    if lock then
      local lv = 0
      if skillTree and skillTree.getNodeProgress then
        local ok, v = pcall(skillTree.getNodeProgress, f.id, lock.treeId, lock.nodeId)
        if ok then lv = tonumber(v) or 0 end
      end
      if lv > 0 then
        table.insert(kept, pair)
      end
    else
      table.insert(kept, pair)
    end
  end
  if #kept == 0 then return nil end
  local copy = deepcopy(f)
  copy.doors = kept
  return copy
end
M.filterLockedDoors = filterLockedDoors

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  local facilities = getFacilities(levelIdentifier)
  if career_career.isActive() then
    for i, dealership in ipairs(facilities.dealerships or {}) do
      if not dealership.remotePurchaseOnly then
        M.walkingMarkerFormatFacility(dealership, elements)
      end
    end
    for i, computer in ipairs(facilities.computers or {}) do
      M.walkingMarkerFormatFacility(computer, elements)
    end
    -- Garage zone markers stay off. Playmode garage computers are walking
    -- markers; recovery yards use their sites zone only as a drop-off volume.
    --for i, garage in ipairs(facilities.garages or {}) do
      --M.zoneMarkerFormatFacility(garage, elements, "poi_garage_2")
    --end
  end
  for i, dragstrip in ipairs(facilities.dragstrips or {}) do
    -- Keep both world triggers (history + rules), but only one big-map hub.
    local before = #elements
    M.vehicleTriggerFormatFacility(dragstrip, elements)
    if dragstrip.dragstripPoiType == "rules" and #elements > before then
      local e = elements[#elements]
      if e and e.markerInfo then
        e.markerInfo.bigmapMarker = nil
      end
    end
  end
  if career_career.isActive() then
    for i, tuningShop in ipairs(facilities.tuningShops or {}) do
      M.walkingMarkerFormatFacility(tuningShop, elements)
    end
    for i, racingTeam in ipairs(facilities.racingTeams or {}) do
      local visible = filterLockedDoors(racingTeam)
      if visible then
        M.walkingMarkerFormatFacility(visible, elements)
      end
    end
    -- Roleplay POIs (bus / paramedic / police): career-only.
    -- Do not match logistics hubs like policeStation / hospital.
    local function resolveRoleplayPoi(f)
      local id = tostring(f.id or "")
      local org = tostring(f.associatedOrganization or "")

      -- Per-map ids/orgs: policeLoaner, ecuPoliceLoaner, arPoliceLoaner, etc.
      if id == "policeLoaner" or id == "policeWork"
          or org == "policeLoaner" or org == "policeWork"
          or string.find(id, "PoliceLoaner", 1, true) or string.find(id, "PoliceWork", 1, true)
          or string.find(org, "PoliceLoaner", 1, true) or string.find(org, "PoliceWork", 1, true) then
        return { type = "policeWork", icon = "poi_delivery_round", cardIcon = "strobeLights" }
      end
      -- Per-map ids/orgs: busWork, ecuBusWork, arBusWork, jriBusWork, etc.
      if id == "busWork" or org == "busWork"
          or string.find(id, "BusWork", 1, true) or string.find(org, "BusWork", 1, true) then
        return { type = "busWork", icon = "poi_pickup_round", cardIcon = "bus" }
      end
      if id == "wcuParamedicWork" or id == "frmc" or org == "wcuParamedicWork"
          or org == "ecuParamedicWork" or string.find(string.lower(org), "paramedic", 1, true) then
        return { type = "paramedicWork", icon = "poi_fast_delivery_round", cardIcon = "strobeLights" }
      end
      return nil
    end

    for _, f in ipairs(facilities.deliveryProviders or {}) do
      local cfg = resolveRoleplayPoi(f)
      if cfg then
        local pos = getDeliveryProviderPosition(f)
        if pos then
          table.insert(elements, {
            id = f.id,
            data = { type = cfg.type, missionId = f.id },
            clusterType = "walkingMarker",
            markerInfo = {
              bigmapMarker = {
                pos = pos,
                icon = cfg.icon,
                name = f.name or f.id,
                description = f.description or "",
                thumbnail = f.preview,
                previews = f.preview and { f.preview } or {},
                cardIcon = cfg.cardIcon,
              },
            },
          })
        end
      end
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel

M.onGetRawPoiListForTutorial = function(elements)
  local facilities = getFacilities("west_coast_usa")
  for i, dragstrip in ipairs(facilities.dragstrips or {}) do
    if dragstrip.isTutorialForDragstrip then
      M.vehicleTriggerFormatFacility(dragstrip, elements)
    end
  end
end

-- Public tuning tents open the tuning UI directly. Refusing to open their computer menu
-- lives in career_modules_computer.openMenu, so every caller is covered.
local function openDirectTuning(computerFacility)
  if not computerFacility or not career_modules_tuning then
    return
  end

  local inventoryId = career_modules_inventory.getInventoryIdsInClosestGarage(true)
  if not inventoryId or not career_modules_inventory.getMapInventoryIdToVehId()[inventoryId] then
    guihooks.trigger('toastrMsg', {
      type = "error",
      title = "Tuning",
      msg = "Park your vehicle in the tent to tune it."
    })
    return
  end

  if career_modules_insurance_insurance and career_modules_insurance_insurance.inventoryVehNeedsRepair
      and career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) then
    guihooks.trigger('toastrMsg', {
      type = "error",
      title = "Tuning",
      msg = "Repair your vehicle before tuning."
    })
    return
  end

  if career_career and career_career.hasBoughtStarterVehicle and not career_career.hasBoughtStarterVehicle() then
    guihooks.trigger('toastrMsg', {
      type = "error",
      title = "Tuning",
      msg = "You need to buy a starter vehicle first."
    })
    return
  end

  if career_modules_permissions then
    local reason = career_modules_permissions.getStatusForTag({"tuning", "vehicleModification"}, {inventoryId = inventoryId})
    if reason and not reason.allow then
      guihooks.trigger('toastrMsg', {
        type = "error",
        title = "Tuning",
        msg = (reason.label or "Tuning is not available right now.")
      })
      return
    end
  end

  career_modules_tuning.start(inventoryId, computerFacility.id)
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.facility then
      local data = {
        icon = elem.facility.playModeIconName or elem.facility.icon,
        heading = elem.facility.name,
        preheadings = {facilityTypeToUiLabelSingular[elem.facility.type]},
        sorting = {
          type = elem.type,
          id = elem.id
        }
      }
      if elem.type == "garage" then
        data.buttonLabel = "ui.career.openGarageTitle"
        data.buttonFun = function() gameplay_garageMode.start(true) end
        table.insert(activityData, data)
      end
      -- gasStations are handled in gasStations.lua now
      if elem.type == "dealership" then
        data.buttonLabel = "ui.facilities.activity.viewInventory"
        data.buttonFun = function() career_modules_vehicleShopping.openShop(elem.facility.id) end
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        table.insert(activityData, data)
      end
      if elem.type == "computer" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        if elem.facility.openTuningDirectly then
          data.preheadings = {"Tuning Station"}
          data.buttonLabel = "Tune your vehicle"
          data.buttonFun = function()
            if career_career.isActive() then
              openDirectTuning(elem.facility)
            end
          end
        else
          local accessible = career_modules_garageManager.isAccessibleGarage(elem.facility.garageId)
          data.buttonLabel = accessible and "ui.facilities.activity.useComputer" or "Purchase Garage"
          data.buttonFun = function()
            if career_career.isActive() then
              if not career_modules_garageManager.isAccessibleGarage(elem.facility.garageId) then
                career_modules_garageManager.showPurchaseGaragePrompt(elem.facility.garageId)
              else
                career_modules_computer.openMenu(elem.facility, false)
              end
            end
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "dragstrip" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
           icon = prop.icon or "drag02",
           keyLabel = prop.keyLabel,
           valueLabel = prop.valueLabel,
         })
        end
        local poiType = elem.facility.dragstripPoiType or "history"
        if poiType == "rules" then
          data.buttonLabel = "ui.facilities.activity.dragstripRulesSetup"
          data.buttonFun = function()
            if gameplay_drag_dragBridge and gameplay_drag_dragBridge.openRulesScreen then
              gameplay_drag_dragBridge.openRulesScreen(elem.facility)
            end
          end
        else
          data.buttonLabel = "ui.facilities.activity.viewHistory"
          data.buttonFun = function()
            gameplay_drag_dragBridge.openHistoryScreen(elem.facility)
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "tuningShop" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        local tuningInfo = career_modules_business_businessManager.getBusinessInfo("tuningShop", elem.facility.id)
        if career_modules_business_businessManager.isPurchasedBusiness("tuningShop", elem.facility.id) then
          data.heading = (tuningInfo and tuningInfo.name) or elem.facility.name
          data.buttonLabel = "Open " .. ((tuningInfo and tuningInfo.name) or "Tuning Shop")
        else
          data.buttonLabel = "Purchase Business"
        end
        data.buttonFun = function()
          if career_career.isActive() then
            if not career_modules_business_businessManager.isPurchasedBusiness("tuningShop", elem.facility.id) then
              career_modules_business_businessManager.showPurchaseBusinessPrompt("tuningShop", elem.facility.id)
            else
              career_modules_business_businessManager.openBusinessMenu("tuningShop", elem.facility.id)
            end
          end
        end
        table.insert(activityData, data)
      end
      if elem.type == "racingTeam" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        local mgr = career_modules_business_businessManager
        local purchased = mgr.isPurchasedBusiness("racingTeam", elem.facility.id) == true
        local racingInfo = mgr.getBusinessInfo("racingTeam", elem.facility.id)
        if purchased then
          local racingName = (racingInfo and racingInfo.name) or elem.facility.name
          if racingName == "Racing Team" then
            racingName = elem.facility.name or racingName
          end
          data.heading = racingName
          data.buttonLabel = "Open"
        else
          data.buttonLabel = "Purchase Business"
        end
        data.buttonFun = function()
          if career_career.isActive() then
            if not career_modules_business_businessManager.isPurchasedBusiness("racingTeam", elem.facility.id) then
              career_modules_business_businessManager.showPurchaseBusinessPrompt("racingTeam", elem.facility.id)
            else
              career_modules_business_businessManager.openBusinessMenu("racingTeam", elem.facility.id)
            end
          end
        end
        table.insert(activityData, data)
      end
    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData

M.getFacilities = getFacilities
M.getFacility = getFacility
M.getFacilityIfExists = function(type, id) return getFacility(type, id, true) end
M.getFacilitiesByType = getFacilitiesByType
M.getGarage = getGarage
M.getGasStation = getGasStation
M.getDealership = getDealership
M.getAverageDoorPositionForFacility = getAverageDoorPositionForFacility
M.getClosestDoorPositionForFacility = getClosestDoorPositionForFacility
M.getParkingSpotsForFacility = getParkingSpotsForFacility
M.getZonesForFacility = getZonesForFacility
M.getGaragePosRot = getGaragePosRot

return M
