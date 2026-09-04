local M = {}

M.dependencies = { 'gameplay_events_freeroam_competitiveTrackFlow' }

local proxyDriverRaceRequestByBusiness = {}

local function normalizeBusinessId(value)
  return tonumber(value) or value
end

local function cloneRequest(req)
  if not req or type(req) ~= "table" then
    return nil
  end
  local copy = {}
  for k, v in pairs(req) do
    copy[k] = v
  end
  return copy
end

local function getRacingTeamModule()
  return rawget(_G, "career_modules_business_racingTeam")
end

local function getTrackFlowModule()
  return gameplay_events_freeroam_competitiveTrackFlow
end

local function invalidResponse(err)
  return { ok = false, err = err or "lua_error" }
end

local function beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  local ctf = getTrackFlowModule()
  if not ctf or not ctf.beginRacingTeamProxyRaceFromBusinessComputer then
    return invalidResponse("no_track_flow")
  end
  return ctf.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
end

local function setProxyDriverRaceRequest(businessId, req)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local id = tostring(businessId)
  if req and type(req) == "table" then
    proxyDriverRaceRequestByBusiness[id] = cloneRequest(req)
  else
    proxyDriverRaceRequestByBusiness[id] = nil
  end
  return proxyDriverRaceRequestByBusiness[id]
end

local function getProxyDriverRaceRequest(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local id = tostring(businessId)
  return cloneRequest(proxyDriverRaceRequestByBusiness[id])
end

local function clearProxyRequestStorage(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local id = tostring(businessId)
  proxyDriverRaceRequestByBusiness[id] = nil
end

local function loadPersistedProxyDriverRaceRequest(businessId, persistedRequest)
  if type(persistedRequest) == "table" then
    return setProxyDriverRaceRequest(businessId, persistedRequest)
  end
  return setProxyDriverRaceRequest(businessId, nil)
end

local function getPersistedProxyDriverRaceRequestForSave(businessId)
  return getProxyDriverRaceRequest(businessId)
end

local function onCareerActivated()
  proxyDriverRaceRequestByBusiness = {}
end

local function notifyProxyRaceRequested(opts)
  if extensions and extensions.hook then
    pcall(function()
      extensions.hook("onRacingTeamProxyRaceRequested", opts)
    end)
  end
end

function M.requestProxyDriverRace(opts)
  if type(opts) ~= "table" then
    return { ok = false, err = "invalid_opts" }
  end
  local rt = getRacingTeamModule()
  if not rt or not rt.proxyDriverRaceValidateAndBuildRequest then
    return { ok = false, err = "no_racing_team" }
  end
  local pack = rt.proxyDriverRaceValidateAndBuildRequest(opts)
  if not pack or pack.ok ~= true then
    return pack or { ok = false, err = "validate_failed" }
  end
  setProxyDriverRaceRequest(pack.businessId, pack.request)
  if rt.persistRacingTeamBusinessJson then
    rt.persistRacingTeamBusinessJson(pack.businessId)
  end
  local rbd = gameplay_raceBusinessDriver
  if rbd and rbd.savePreRaceWorldState then
    if not (rbd.hasPreRaceWorldState and rbd.hasPreRaceWorldState()) then
      rbd.savePreRaceWorldState()
    end
  end
  local spectateStaging = opts and opts.spectateStaging == true
  local ctfArm = getTrackFlowModule()
  if ctfArm and ctfArm.relayRacingTeamProxyOverlay then
    ctfArm.relayRacingTeamProxyOverlay({
      visible = true,
      businessId = pack.request and pack.request.businessId,
      inRace = false,
      spectateStaging = spectateStaging,
    })
  elseif guihooks and guihooks.trigger then
    guihooks.trigger("racingTeamProxyOverlay", {
      visible = true,
      businessId = pack.request and pack.request.businessId,
      inRace = false,
      spectateStaging = spectateStaging,
    })
  end
  if pack.request then
    notifyProxyRaceRequested(pack.request)
  end
  return { ok = true }
end

function M.simulateRacingTeamProxyRace(opts)
  if type(opts) ~= "table" then
    return invalidResponse("invalid_opts")
  end
  local ctf = getTrackFlowModule()
  local armOpts = {}
  for k, v in pairs(opts) do
    armOpts[k] = v
  end
  armOpts.spectateStaging = true
  local armRes = M.requestProxyDriverRace(armOpts)
  if not armRes or armRes.ok ~= true then
    if ctf and ctf.exitRacingTeamProxyStagingLoadingScreen then
      ctf.exitRacingTeamProxyStagingLoadingScreen()
    end
    return armRes or invalidResponse("request_failed")
  end
  local businessId = normalizeBusinessId(opts.businessId)
  if not businessId then
    if ctf and ctf.exitRacingTeamProxyStagingLoadingScreen then
      ctf.exitRacingTeamProxyStagingLoadingScreen()
    end
    return invalidResponse("missing_business_or_driver")
  end
  local beginRes = beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  if not beginRes or beginRes.ok ~= true then
    if ctf and ctf.exitRacingTeamProxyStagingLoadingScreen then
      ctf.exitRacingTeamProxyStagingLoadingScreen()
    end
  end
  if type(beginRes) ~= "table" then
    return invalidResponse("begin_failed")
  end
  return beginRes
end

function M.clearProxyDriverRaceRequest(businessId)
  clearProxyRequestStorage(businessId)
  local rt = getRacingTeamModule()
  if rt and rt.persistRacingTeamBusinessJson then
    rt.persistRacingTeamBusinessJson(businessId)
  end
end

function M.getProxyDriverAiDifficultyBlendT(businessId, driverId)
  local rt = getRacingTeamModule()
  if rt and rt.getProxyDriverAiDifficultyBlendT then
    return rt.getProxyDriverAiDifficultyBlendT(businessId, driverId)
  end
  return 1
end

local function findProxyDriverRaceRequestForLevel(levelId)
  if type(levelId) ~= "string" or levelId == "" then
    return nil, nil
  end
  local manager = career_modules_business_businessManager
  if not manager or not manager.getPurchasedBusinesses then
    return nil, nil
  end
  local purchased = manager.getPurchasedBusinesses("racingTeam")
  if not purchased then
    return nil, nil
  end
  for bid, _ in pairs(purchased) do
    local req = getProxyDriverRaceRequest(bid)
    if req and req.racingTeamProxyRace and req.levelId == levelId then
      return req, bid
    end
  end
  return nil, nil
end

M.loadPersistedProxyDriverRaceRequest = loadPersistedProxyDriverRaceRequest
M.getPersistedProxyDriverRaceRequestForSave = getPersistedProxyDriverRaceRequestForSave
M.setProxyDriverRaceRequest = setProxyDriverRaceRequest
M.getProxyDriverRaceRequest = getProxyDriverRaceRequest
M.findProxyDriverRaceRequestForLevel = findProxyDriverRaceRequestForLevel
M.onCareerActivated = onCareerActivated
M.beginRacingTeamProxyRaceFromBusinessComputer = beginRacingTeamProxyRaceFromBusinessComputer

return M
