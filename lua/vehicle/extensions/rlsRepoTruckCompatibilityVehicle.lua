-- Compatibility bridge for the optional legacy repo_parts pickup upfit.
--
-- That mod's controls call a model-local `custom_input` extension without
-- declaring it as a controller/dependency. Vehicle/input lifecycle rebuilds
-- can therefore leave the extension unloaded. Its tilt/extend action names
-- also collide with BeamNG's current shared upfit actions, which now write
-- upfit_* electrics instead of the legacy controller's *_input electrics.

local M = {}

local loadRetryTimer = 0
local compatibilityActive = false
local manuallyLoadedController = nil
local loadFailureLogged = false
local previousInputs = {
  tilt = 0,
  extend = 0,
  feet = 0
}

local inputMappings = {
  {
    key = "tilt",
    source = "upfit_tilt",
    method = "tiltBed"
  },
  {
    key = "extend",
    source = "upfit_extendRetract",
    method = "extendBed"
  },
  {
    key = "feet",
    source = "upfit_extendRetractFeet",
    method = "extendFeet"
  }
}

local function isRepoTruckPart(partName)
  local normalizedName = string.lower(tostring(partName or ""))
  return normalizedName == "repo_main"
    or normalizedName == "repo_main_long"
    or normalizedName == "repo_parts"
    or normalizedName == "repo_ctrl_ext"
    or normalizedName == "repo_ctrl_int"
    or string.find(normalizedName, "/repo_main", 1, true) ~= nil
    or string.find(normalizedName, "/repo_parts", 1, true) ~= nil
    or string.find(normalizedName, "/repo_ctrl_ext", 1, true) ~= nil
    or string.find(normalizedName, "/repo_ctrl_int", 1, true) ~= nil
end

local function isRepoTruckVehicle()
  for _, partName in pairs((v.config and v.config.parts) or {}) do
    if isRepoTruckPart(partName) then return true end
  end
  for activePartPath in pairs((v.data and v.data.activeParts) or {}) do
    if isRepoTruckPart(activePartPath) then return true end
  end
  return false
end

local function getLegacyController()
  return extensions.custom_input or rawget(_G, "custom_input")
end

local function ensureLegacyControllerLoaded()
  local legacyController = getLegacyController()
  if legacyController then return legacyController end

  -- Vehicle extensions.load() only searches the standard extension roots in
  -- 0.39; repo_parts keeps this module beside the pickup instead. Retain the
  -- normal load attempt for versions where it works, then explicitly load the
  -- model-local module and drive its lifecycle from this bridge.
  extensions.load("custom_input")
  legacyController = getLegacyController()
  if legacyController then return legacyController end

  local ok, result = pcall(dofile, "/vehicles/pickup/lua/custom_input.lua")
  if ok and type(result) == "table" then
    manuallyLoadedController = result
    rawset(_G, "custom_input", result)
    loadFailureLogged = false
    if type(result.onInit) == "function" then
      result.onInit()
    end
    return result
  end

  if not loadFailureLogged then
    log("E", "rlsRepoTruckCompatibilityVehicle", "Unable to load repo truck custom_input.lua: " .. tostring(result))
    loadFailureLogged = true
  end
  return nil
end

local function resetBridgeInputs()
  for key in pairs(previousInputs) do
    previousInputs[key] = 0
  end
end

local function bridgeSharedUpfitInputs(legacyController)
  for _, mapping in ipairs(inputMappings) do
    local value = tonumber(electrics.values[mapping.source]) or 0
    local previousValue = previousInputs[mapping.key] or 0

    -- Do not continually write zero: the repo mod's original actions may be
    -- driving the same input directly. We only clear a command that this
    -- bridge previously supplied.
    if math.abs(value) > 0.001 or math.abs(previousValue) > 0.001 then
      local setter = legacyController[mapping.method]
      if type(setter) == "function" then
        setter(0.5 * value)
      end
    end

    previousInputs[mapping.key] = value
  end
end

local function updateGFX(dt)
  if not compatibilityActive then
    loadRetryTimer = loadRetryTimer + (tonumber(dt) or 0)
    if loadRetryTimer < 1 then return end
    loadRetryTimer = 0
    compatibilityActive = isRepoTruckVehicle()
    if not compatibilityActive then return end
  end

  local legacyController = getLegacyController()
  if not legacyController then
    loadRetryTimer = loadRetryTimer + (tonumber(dt) or 0)
    if loadRetryTimer >= 1 then
      loadRetryTimer = 0
      legacyController = ensureLegacyControllerLoaded()
    end
  else
    loadRetryTimer = 0
  end

  if legacyController then
    bridgeSharedUpfitInputs(legacyController)
    if legacyController == manuallyLoadedController and type(legacyController.updateGFX) == "function" then
      legacyController.updateGFX(dt)
    end
  end
end

local function onExtensionLoaded()
  resetBridgeInputs()
  loadRetryTimer = 0
  compatibilityActive = isRepoTruckVehicle()
  if compatibilityActive then
    ensureLegacyControllerLoaded()
  end
end

local function onReset()
  resetBridgeInputs()
  loadRetryTimer = 0
  compatibilityActive = isRepoTruckVehicle()
  if not compatibilityActive then return end
  local legacyController = ensureLegacyControllerLoaded()
  if legacyController == manuallyLoadedController and type(legacyController.onReset) == "function" then
    legacyController.onReset()
  end
end

local function onExtensionUnloaded()
  if manuallyLoadedController and rawget(_G, "custom_input") == manuallyLoadedController then
    rawset(_G, "custom_input", nil)
  end
  manuallyLoadedController = nil
end

M.updateGFX = updateGFX
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.onExtensionUnloaded = onExtensionUnloaded

return M
