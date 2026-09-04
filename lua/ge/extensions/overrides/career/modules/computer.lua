-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career"}

local computerTetherRangeSphere = 4 --meter
-- Door tether buffer beyond the gameplay area. Too small and the first interact
-- opens then immediately closes when the player's origin is still on the edge.
local computerTetherRangeBox = 2.5 --meter
local tether

local computerFunctions
local computerId
local computerFacilityName
local menuData = {}

-- Tuning tents reuse the computer facility shape so the tuning flow can hang off them,
-- but they are tuning-only spots. Their menu must never open: several computer functions
-- (marketplace, loans, ...) don't gate on facility.functions, so a tent would hand the
-- player a working garage screen.
local function isTuningOnlyFacility(computerFacility)
  return computerFacility ~= nil and computerFacility.openTuningDirectly == true
end

local function clearMenuState()
  computerId = nil
  computerFunctions = nil
  computerFacilityName = nil
  menuData = {}
end

local function rebuildMenuData(resetActiveVehicleIndex)
  if not computerId then return false end

  local computerFacility = menuData and menuData.computerFacility
  if not computerFacility then
    computerFacility = freeroam_facilities.getFacility("computer", computerId)
  end
  if not computerFacility then return false end
  if isTuningOnlyFacility(computerFacility) then
    clearMenuState()
    return false
  end

  if resetActiveVehicleIndex == nil and menuData then
    resetActiveVehicleIndex = menuData.resetActiveVehicleIndex
  end

  computerFunctions = {general = {}, vehicleSpecific = {}}
  computerFacilityName = computerFacility.name

  menuData = {
    vehiclesInGarage = {},
    resetActiveVehicleIndex = resetActiveVehicleIndex,
    computerFacility = computerFacility,
    hasBoughtStarterVehicle = career_career.hasBoughtStarterVehicle()
  }

  local inventoryIds = career_modules_inventory.getInventoryIdsInClosestGarage()
  for _, inventoryId in ipairs(inventoryIds) do
    local vehicleData = {}
    vehicleData.inventoryId = inventoryId
    vehicleData.needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) or nil
    local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
    vehicleData.vehicleName = vehicleInfo and vehicleInfo.niceName
    vehicleData.dirtyDate = vehicleInfo and vehicleInfo.dirtyDate
    table.insert(menuData.vehiclesInGarage, vehicleData)

    computerFunctions.vehicleSpecific[inventoryId] = {}
  end

  extensions.hook("onComputerAddFunctions", menuData, computerFunctions)
  return true
end

local function buildComputerUIData()
  local data = {}
  if not computerFunctions then
    return data
  end

  local invVehicles = career_modules_inventory.getVehicles()

  local computerFunctionsForUI = deepcopy(computerFunctions)
  computerFunctionsForUI.vehicleSpecific = {}

  -- convert keys of the table to string, because js doesnt support number keys
  for inventoryId, computerFunction in pairs(computerFunctions.vehicleSpecific) do
    if invVehicles and invVehicles[inventoryId] then
      computerFunctionsForUI.vehicleSpecific[tostring(inventoryId)] = computerFunction
    end
  end

  local vehiclesForUI = {}
  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local invId = vehicleData.inventoryId
    if invVehicles and invVehicles[invId] then
      local vd = deepcopy(vehicleData)
      local thumb = career_modules_inventory.getVehicleThumbnail(invId)
      if thumb then
        vd.thumbnail = thumb .. "?" .. (vd.dirtyDate or "")
      end
      vd.inventoryId = tostring(invId)
      table.insert(vehiclesForUI, vd)
    end
  end

  data.computerFunctions = computerFunctionsForUI
  data.vehicles = vehiclesForUI
  data.facilityName = computerFacilityName
  data.resetActiveVehicleIndex = menuData.resetActiveVehicleIndex
  data.computerId = computerId
  return data
end

local function openMenu(computerFacility, resetActiveVehicleIndex, activityElement)
  if isTuningOnlyFacility(computerFacility) then
    clearMenuState()
    career_career.closeAllMenus()
    return
  end
  computerId = computerFacility.id
  menuData.computerFacility = computerFacility
  rebuildMenuData(resetActiveVehicleIndex)

  local door = computerFacility.doors and computerFacility.doors[1]
  tether = nil
  if door then
    tether = career_modules_tether.startDoorTether(door, computerTetherRangeBox, M.closeMenu)
  end
  if not tether then
    local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(computerFacility)
    if computerPos then
      tether = career_modules_tether.startSphereTether(computerPos, computerTetherRangeSphere, M.closeMenu)
    end
  end

  extensions.ui_router.navigate("career.computer")
  extensions.hook("onComputerMenuOpened")
end

local function refreshMenu(resetActiveVehicleIndex)
  if not rebuildMenuData(resetActiveVehicleIndex) then return false end
  guihooks.trigger("computerUIData", buildComputerUIData())
  return true
end

local function computerButtonCallback(buttonId, inventoryId)
  if not computerFunctions then return end
  local functionData
  if inventoryId then
    functionData = computerFunctions.vehicleSpecific[inventoryId] and computerFunctions.vehicleSpecific[inventoryId][buttonId]
  else
    functionData = computerFunctions.general[buttonId]
  end
  if not functionData then return end

  functionData.callback(computerId)
end

local function getComputerUIData()
  -- Always rebuild from live garage state so returning from inventory/repair is current.
  -- No usable computer means the screen was reached without one being opened (a stray
  -- route back out of tuning at a tent), so leave instead of rendering an empty garage.
  if not computerId or not rebuildMenuData() then
    career_career.closeAllMenus()
    return {}
  end
  return buildComputerUIData()
end

local function onMenuClosed()
  if tether then tether.remove = true tether = nil end
end

local function closeMenu()
  career_career.closeAllMenus()
end

local function openComputerMenuById(computerIdArg)
  local computer = freeroam_facilities.getFacility("computer", computerIdArg)
  career_modules_computer.openMenu(computer)
end

M.reasons = {
  tutorialActive = {
    type = "text",
    label = "Disabled during tutorial."
  },
  hasBoughtStarterVehicle = {
    type = "text",
    label = "You need to buy a starter vehicle first."
  },
  needsRepair = {
    type = "needsRepair",
    label = "The vehicle needs to be repaired first."
  }
}

local function getComputerId()
  return computerId
end

M.openMenu = openMenu
M.refreshMenu = refreshMenu
M.openComputerMenuById = openComputerMenuById
M.onMenuClosed = onMenuClosed
M.closeMenu = closeMenu
M.getComputerUIData = getComputerUIData
M.computerButtonCallback = computerButtonCallback
M.getComputerId = getComputerId

return M
