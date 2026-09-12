local M = {}

local WRAP_MARKER = "__rlsBigMapOriginalPopPauseRequest"
local popWrapped = false

local function unblockBigMapVehicleInput()
  if not core_input_actionFilter or not core_input_actionFilter.addAction then return end
  core_input_actionFilter.addAction(0, "bigmapBlockedActions", false)
end

local function wrapPopPauseRequest()
  if not simTimeAuthority or type(simTimeAuthority.popPauseRequest) ~= "function" then
    return false
  end

  local originalPop = simTimeAuthority[WRAP_MARKER]
  if type(originalPop) == "function" then
    popWrapped = true
    return true
  end

  if popWrapped then return true end

  originalPop = simTimeAuthority.popPauseRequest
  simTimeAuthority[WRAP_MARKER] = originalPop
  simTimeAuthority.popPauseRequest = function(id)
    if id == "bigMap" then
      unblockBigMapVehicleInput()
    end
    return originalPop(id)
  end
  popWrapped = true
  return true
end

local function unwrapPopPauseRequest()
  if not simTimeAuthority then
    popWrapped = false
    return
  end
  local originalPop = simTimeAuthority[WRAP_MARKER]
  if type(originalPop) == "function" then
    simTimeAuthority.popPauseRequest = originalPop
  end
  simTimeAuthority[WRAP_MARKER] = nil
  popWrapped = false
end

M.onExtensionLoaded = function()
  wrapPopPauseRequest()
end

M.onExtensionUnloaded = function()
  unwrapPopPauseRequest()
end

M.onUpdate = function()
  if not popWrapped then
    wrapPopPauseRequest()
  end
end

return M
