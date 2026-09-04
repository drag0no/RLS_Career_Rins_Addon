-- Wraps core_groundMarkers so each setPath owns a generation token.
-- Callers store the token and may only clear that route if it is still active.
-- Stock resetAll still force-clears (level/mission exit) and invalidates tokens.
-- Also keeps an existing destination from going blank when the planner hitchs.

local M = {}
M.dependencies = {'core_groundMarkers'}

local origSetPath
local origResetAll
local origSendToApp
local origGenerateRouteDecals
local origOnPreRender
local generation = 0
local lastReseedAt = 0
local RESEED_INTERVAL = 0.5

local function currentGeneration()
  return generation
end

local function bump()
  generation = generation + 1
  return generation
end

local function hasActiveDestination()
  local gm = rawget(_G, 'core_groundMarkers')
  return gm ~= nil and gm.endWP ~= nil
end

local function hasRoutePath()
  local gm = rawget(_G, 'core_groundMarkers')
  local path = gm and gm.routePlanner and gm.routePlanner.path
  return path ~= nil and path[1] ~= nil and path[1].pos ~= nil
end

local function reseedIfNeeded()
  if not origSetPath or not hasActiveDestination() or hasRoutePath() then
    return
  end
  local now = os.clock()
  if (now - lastReseedAt) < RESEED_INTERVAL then
    return
  end
  lastReseedAt = now
  local gm = rawget(_G, 'core_groundMarkers')
  origSetPath(gm.endWP, {
    clearPathOnReachingTarget = gm.clearPathOnReachingTarget,
    step = gm.stepDistance,
    color = gm.color,
    cutOffDrivability = gm.cutOffDrivability,
    penaltyAboveCutoff = gm.penaltyAboveCutoff,
    penaltyBelowCutoff = gm.penaltyBelowCutoff,
    renderDecals = gm.renderDecals,
  })
end

local function wrappedSetPath(wp, options)
  options = options or {}
  if wp == nil and options.generationToken ~= nil and options.generationToken ~= generation then
    return false
  end
  origSetPath(wp, options)
  return bump()
end

local function wrappedResetAll()
  origResetAll()
  bump()
end

local function wrappedSendToApp()
  if hasActiveDestination() and not hasRoutePath() then
    return
  end
  origSendToApp()
end

local function wrappedGenerateRouteDecals(startPos)
  if not hasRoutePath() then
    return
  end
  origGenerateRouteDecals(startPos)
end

local function wrappedOnPreRender(dt)
  local gm = rawget(_G, 'core_groundMarkers')
  if gm and gm.endWP then
    local veh = getPlayerVehicle(0)
    if veh and gm.routePlanner and gm.routePlanner.trackVehicle then
      gm.routePlanner:trackVehicle(veh)
    end
    if not hasRoutePath() then
      reseedIfNeeded()
    end
    if not hasRoutePath() then
      return
    end
  end
  origOnPreRender(dt)
end

local function clearOwnedPath(token)
  if token == nil or token ~= generation then
    return false
  end
  origSetPath(nil)
  bump()
  return true
end

local function install()
  local gm = rawget(_G, 'core_groundMarkers')
  if type(gm) ~= 'table' or type(gm.setPath) ~= 'function' then
    return false
  end

  if gm.setPath ~= wrappedSetPath then
    origSetPath = gm.setPath
    origResetAll = gm.resetAll
    gm.setPath = wrappedSetPath
    if type(origResetAll) == 'function' then
      gm.resetAll = wrappedResetAll
    end
    gm.clearOwnedPath = clearOwnedPath
    gm.getPathGeneration = currentGeneration
  end

  if type(gm.sendToApp) == 'function' and gm.sendToApp ~= wrappedSendToApp then
    origSendToApp = gm.sendToApp
    gm.sendToApp = wrappedSendToApp
  end
  if type(gm.generateRouteDecals) == 'function' and gm.generateRouteDecals ~= wrappedGenerateRouteDecals then
    origGenerateRouteDecals = gm.generateRouteDecals
    gm.generateRouteDecals = wrappedGenerateRouteDecals
  end
  if type(gm.onPreRender) == 'function' and gm.onPreRender ~= wrappedOnPreRender then
    origOnPreRender = gm.onPreRender
    gm.onPreRender = wrappedOnPreRender
    if extensions and extensions.hookUpdate then
      extensions.hookUpdate('onPreRender')
    end
  end
  return true
end

local function onExtensionLoaded()
  install()
end

local function onClientStartMission()
  install()
end

local function onPreRender()
  install()
  reseedIfNeeded()
end

M.install = install
M.onExtensionLoaded = onExtensionLoaded
M.onClientStartMission = onClientStartMission
M.onPreRender = onPreRender

return M
