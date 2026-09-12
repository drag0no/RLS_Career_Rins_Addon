local M = {}

local wrapped = false
local origUpdateGFX = nil
local savedGear = nil
local savedSpeed = 0
local wasPaused = false

local function restoreGear(index)
  if index == nil then return end
  local gb = powertrain and powertrain.getDevice and powertrain.getDevice("gearbox")
  if gb and gb.setGearIndex then
    gb:setGearIndex(index, 0)
    if electrics and electrics.values then
      electrics.values.gearIndex = index
    end
    return
  end
  if not powertrain or not powertrain.getDevicesByType then return end
  for _, typeName in ipairs({"automaticGearbox", "dctGearbox", "manualGearbox", "sequentialGearbox"}) do
    local devices = powertrain.getDevicesByType(typeName)
    if devices then
      for _, device in ipairs(devices) do
        if device.setGearIndex then
          device:setGearIndex(index, 0)
          if electrics and electrics.values then
            electrics.values.gearIndex = index
          end
          return
        end
      end
    end
  end
end

local function afterController(dt)
  local ev = electrics and electrics.values
  if not ev then return end
  if ev.gearboxMode == "none" then return end

  local speed = ev.wheelspeed or 0
  local gear = ev.gearIndex

  if not dt or dt <= 1e-4 then
    wasPaused = true
    return
  end

  local resumed = wasPaused
  wasPaused = false
  local dumped = savedGear ~= nil and gear ~= nil and savedSpeed > 12
    and math.abs(savedGear) >= 2 and math.abs(gear) <= 1 and speed > 12

  if restoreArmed then
    if savedGear ~= nil and math.abs(savedGear) > 1 then
      if gear ~= savedGear then
        local looksDumped = gear ~= nil and math.abs(gear) <= 1
        if looksDumped then
          restoreGear(savedGear)
          restoreArmed = false
          return
        end
        restoreArmed = false
      else
        restoreArmed = false
      end
    else
      restoreArmed = false
    end
  end

  savedGear = gear
  savedSpeed = speed
end

local function wrapController()
  if wrapped then return true end
  if not controller or not controller.mainController then return false end
  local mc = controller.mainController
  if type(mc.updateGFX) ~= "function" then return false end
  origUpdateGFX = mc.updateGFX
  mc.updateGFX = function(dt)
    origUpdateGFX(dt)
    afterController(dt)
  end
  if controller.cacheAllControllerFunctions then
    controller.cacheAllControllerFunctions()
  end
  wrapped = true
  return true
end

function M.onExtensionLoaded()
  wrapController()
end

function M.onReset()
  savedGear = nil
  savedSpeed = 0
  lastClock = 0
  restoreArmed = false
  if wrapped and controller and controller.mainController and origUpdateGFX then
    controller.mainController.updateGFX = origUpdateGFX
    wrapped = false
    origUpdateGFX = nil
  end
  wrapController()
end

function M.updateGFX(dt)
  if not wrapped then
    wrapController()
    afterController(dt)
  end
end

return M
