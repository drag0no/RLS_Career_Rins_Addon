-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local routePlanner = require('gameplay/route/route')()

local basePrice = 5
local pricePerM = 0.08

local function getRoadDistanceBetween(startPos, endPos)
  if not startPos or not endPos then return nil end
  routePlanner:setupPath(startPos, endPos)
  if routePlanner.path and routePlanner.path[1] and routePlanner.path[1].distToTarget then
    return routePlanner.path[1].distToTarget or 0
  else
    -- Fallback: calculate straight-line distance if route planner fails
    return (endPos - startPos):length()
  end
end

local function getPriceForRoadDistance(distance)
  if not distance or distance < 0 then
    log("W", "QuickTravel", "Invalid distance calculated, using fallback")
    distance = 0
  end

  log("D", "QuickTravel", string.format("Distance to target: %.2f, basePrice: %.2f, pricePerM: %.2f", distance, basePrice, pricePerM))

  local price
  if distance < 300 then
    price = math.max(0, basePrice + round(distance * pricePerM * 100) / 100) -- Ensure minimum price even for short distances
  else
    price = basePrice + round(distance * pricePerM * 100) / 100
  end

  -- Scale fast travel cost by global economy index
  local globalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  price = math.floor(price * globalIndex * 100 + 0.5) / 100

  log("D", "QuickTravel", string.format("Price: %.2f (distance: %.2f)", price, distance))
  return price, distance
end

local function getRoadRouteQuote(startPos, endPos)
  local distance = getRoadDistanceBetween(startPos, endPos)
  local price = getPriceForRoadDistance(distance)
  return {
    price = price or 0,
    roadDistance = distance or 0
  }
end

local function getPriceBetween(startPos, endPos)
  local quote = getRoadRouteQuote(startPos, endPos)
  return quote.price, quote.roadDistance
end

local function getPriceForQuickTravel(pos)
  local playerVehicle = getPlayerVehicle(0)
  if not playerVehicle then return 0, 0 end
  return getPriceBetween(playerVehicle:getPosition(), pos)
end

local function faceWalkDirection(front)
  if not front then return end
  local dir = vec3(front)
  dir.z = 0
  if dir:length() < 1e-4 then
    dir = vec3(0, 1, 0)
  else
    dir:normalize()
  end
  core_vehicleBridge.requestValue(getPlayerVehicle(0), function()
    if gameplay_walk.isWalking() then
      gameplay_walk.setRot(dir, vec3(0, 0, 1))
    end
  end, 'ping')
end

local function directionFromRot(rot)
  if not rot then return nil end
  local q = rot
  if type(rot) == "table" then
    q = quat(rot[1] or 0, rot[2] or 0, rot[3] or 0, rot[4] or 1)
  end
  return q * vec3(0, 1, 0)
end

local function quickTravelToPos(pos, useWalkingMode, reasonString, rot)
  local price = getPriceForQuickTravel(pos)
  if career_modules_playerAttributes.getAttributeValue("money") < price then return end
  if useWalkingMode then
    gameplay_walk.setWalkingMode(true)
    spawn.safeTeleport(getPlayerVehicle(0), pos)
    faceWalkDirection(directionFromRot(rot))
  end
  -- TODO if we want to quicktravel with the vehicle, then we need to set the partcondition reset point first
  career_modules_playerAttributes.addAttributes({money=-price}, {tags={"quickTravel","buying"}, label=(reasonString or "ui.career.attributeLog.quickTravelPaid")})
end

local function quickTravelToGarage(garagePoi)
  local garage = freeroam_facilities.getGarage(garagePoi.id)
  if not garage then return end
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(garage)
  if parkingSpots[1] then
    local spot = parkingSpots[1]
    quickTravelToPos(spot.pos, true, "ui.career.attributeLog.quickTravelGarageTaxi", spot.rot)
  end
end

local function getPriceForQuickTravelToGarage(garage)
  local pos, rot = freeroam_facilities.getGaragePosRot(garage)
  return getPriceForQuickTravel(pos)
end

M.quickTravelToPos = quickTravelToPos
M.quickTravelToGarage = quickTravelToGarage
M.getPriceForQuickTravel = getPriceForQuickTravel
M.getPriceForQuickTravelToGarage = getPriceForQuickTravelToGarage
M.getRoadDistanceBetween = getRoadDistanceBetween
M.getPriceBetween = getPriceBetween
M.getRoadRouteQuote = getRoadRouteQuote

return M
