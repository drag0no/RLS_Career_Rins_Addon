-- Racing team: player rides in the team car while AI drives; default camera = external during proxy race.
-- Saves world state before the event, locks driving input during the race, restores after.
-- Spawn at player_stage_*, rivals, countdown, and AI path are handled by freeroam / aiRacers (wired separately).

local M = {}

M.dependencies = { "core_camera", "core_jobsystem", "gameplay_events_freeroam_competitiveTrackFlow" }

-- career_modules_business_racingTeam depends on us, and the career loader pins
-- every career module to "manual" unload. We only get pulled in as a dependency,
-- so we default to "auto" and a level switch drops us -- leaving racingTeam with a
-- permanently unresolved dependency (and a resolveDependencies warning on every
-- later extensions.load). Pin ourselves to the same lifetime as the career modules.
function M.onInit()
  setExtensionUnloadMode(M, "manual")
end

local mRideAlongVehId = nil
local mInputLocked = false
local mVehicleFrozen = false
local mPreRaceState = nil
local mCameraNameBeforeRideAlong = nil

local function applyProxyExternalCameraDeferred()
  if not core_camera or not core_camera.setByName then
    return
  end
  local function run()
    pcall(function()
      core_camera.setByName(0, "external", true)
    end)
  end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0.05)
      run()
    end)
  else
    run()
  end
end

local function getPlayerVehObj()
  if not be or not be.getPlayerVehicle then
    return nil
  end
  return be:getPlayerVehicle(0)
end

local function getPlayerVehId()
  local o = getPlayerVehObj()
  return o and o:getID() or nil
end

--- Serialize position + rotation for restore (best-effort).
local function captureVehicleTransform(vehObj)
  if not vehObj or not vehObj.getPosition then
    return nil
  end
  local pos = vehObj:getPosition()
  local q = vehObj.getRotation and vehObj:getRotation()
  local px, py, pz = pos.x, pos.y, pos.z
  local qx, qy, qz, qw = 0, 0, 0, 1
  if q then
    qx, qy, qz, qw = q.x or 0, q.y or 0, q.z or 0, q.w or 1
  end
  return {
    pos = { px, py, pz },
    rot = { qx, qy, qz, qw },
    levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil,
    walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false,
  }
end

--- Call before teleporting the player into the team car for a business race.
function M.savePreRaceWorldState()
  local pv = getPlayerVehObj()
  local pid = getPlayerVehId()
  mPreRaceState = {
    playerVehicleId = pid,
    transform = pv and captureVehicleTransform(pv) or nil,
  }
end

local function unfreezePlayerVehicle(vehObj)
  if vehObj and core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function()
      core_vehicleBridge.executeAction(vehObj, "setFreeze", false)
    end)
  end
  if vehObj and vehObj.queueLuaCommand then
    pcall(function()
      vehObj:queueLuaCommand("if input and input.setEnabled then input.setEnabled(true) end")
    end)
  end
  local aiRacers = gameplay_events_freeroam_aiRacers
  if aiRacers and aiRacers.setPlayerFreeze then
    pcall(function()
      aiRacers.setPlayerFreeze(false)
    end)
  end
end

--- Teleport player vehicle back to saved transform (same level). Does not respawn removed vehicles.
--- If the player was walking, re-enter walking mode so they are not stuck in the unicycle as a vehicle.
function M.restorePreRaceWorldState()
  if not mPreRaceState or not mPreRaceState.transform then
    mPreRaceState = nil
    return false
  end
  local t = mPreRaceState.transform
  local curLevel = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if t.levelId and curLevel and t.levelId ~= curLevel then
    mPreRaceState = nil
    return false
  end
  local p = t.pos
  local r = t.rot

  -- Walking must be restored from the current (team) car. enterVehicle(unicycle)
  -- first makes walk.lua treat walking as already active, so setWalkingMode(true)
  -- is a no-op and the player stays seated in the unicycle.
  if t.walking and gameplay_walk and gameplay_walk.setWalkingMode and p then
    local walkPos = vec3(p[1], p[2], p[3])
    local walkRot = nil
    if r and quat then
      walkRot = quat(r[1], r[2], r[3], r[4])
    end
    local pv = getPlayerVehObj()
    local alreadyUnicycle = pv and pv.getJBeamFilename and pv:getJBeamFilename() == "unicycle"
    if alreadyUnicycle then
      pcall(function()
        gameplay_walk.setWalkingMode(false, nil, nil, true)
      end)
    end
    pcall(function()
      gameplay_walk.setWalkingMode(true, walkPos, walkRot, true)
    end)
    unfreezePlayerVehicle(getPlayerVehObj())
    mPreRaceState = nil
    return true
  end

  local savedVehId = mPreRaceState.playerVehicleId
  if savedVehId and be and be.getObjectByID and be.getPlayerVehicleID and be.enterVehicle then
    local curId = be:getPlayerVehicleID(0)
    if curId ~= savedVehId then
      local oldObj = be:getObjectByID(savedVehId)
      if oldObj then
        pcall(function()
          be:enterVehicle(0, oldObj)
        end)
      end
    end
  end
  local pv = getPlayerVehObj()
  if pv and pv.setPosRot and p and r then
    pcall(function()
      pv:setPosRot(p[1], p[2], p[3], r[1], r[2], r[3], r[4])
    end)
    unfreezePlayerVehicle(pv)
  else
    mPreRaceState = nil
    return false
  end
  mPreRaceState = nil
  return true
end

function M.clearPreRaceWorldState()
  mPreRaceState = nil
end

function M.hasPreRaceWorldState()
  return mPreRaceState ~= nil
end

function M.setVehicleInputLocked(vehId, locked)
  local vid = tonumber(vehId)
  if not vid then
    return
  end
  local obj = be and be.getObjectByID and be:getObjectByID(vid)
  if not obj then
    return
  end
  local en = locked and "false" or "true"
  obj:queueLuaCommand("if input and input.setEnabled then input.setEnabled(" .. en .. ") end")
  if locked and vid == getPlayerVehId() then
    mInputLocked = true
    mRideAlongVehId = vid
  elseif not locked and vid == mRideAlongVehId then
    mInputLocked = false
  end
end

function M.setVehicleFrozen(vehId, freeze)
  if not core_vehicleBridge or not core_vehicleBridge.executeAction then
    return
  end
  local obj = be and be.getObjectByID and be:getObjectByID(vehId)
  if not obj then
    return
  end
  pcall(function()
    core_vehicleBridge.executeAction(obj, "setFreeze", freeze and true or false)
  end)
  if freeze and tonumber(vehId) == getPlayerVehId() then
    mVehicleFrozen = true
  elseif not freeze then
    mVehicleFrozen = false
  end
end

--- After player is in the team car, disable driving input (AI controls the vehicle).
function M.beginRideAlongSession(teamCarVehId)
  local vid = tonumber(teamCarVehId)
  if not vid then
    return false
  end
  mRideAlongVehId = vid
  if core_camera and core_camera.getActiveCamName then
    mCameraNameBeforeRideAlong = core_camera.getActiveCamName(0)
  else
    mCameraNameBeforeRideAlong = nil
  end
  M.setVehicleInputLocked(vid, true)
  applyProxyExternalCameraDeferred()
  return true
end

function M.endRideAlongSession()
  if mRideAlongVehId then
    M.setVehicleInputLocked(mRideAlongVehId, false)
    if mVehicleFrozen then
      M.setVehicleFrozen(mRideAlongVehId, false)
    end
  end
  mRideAlongVehId = nil
  mInputLocked = false
  mVehicleFrozen = false
  -- Walking restore sets the unicycle camera itself. Restoring the ride-along
  -- vehicle camera first leaves the player seated in the unicycle.
  local restoringWalk = mPreRaceState and mPreRaceState.transform and mPreRaceState.transform.walking
  if restoringWalk then
    mCameraNameBeforeRideAlong = nil
    return
  end
  local prev = mCameraNameBeforeRideAlong
  mCameraNameBeforeRideAlong = nil
  if prev and prev ~= "" and core_camera and core_camera.setByName then
    pcall(function()
      core_camera.setByName(0, prev, false)
    end)
  elseif core_camera and core_camera.resetCamera then
    pcall(function()
      core_camera.resetCamera(0)
    end)
  end
end

function M.isRideAlongActive()
  return mRideAlongVehId ~= nil
end

function M.getRideAlongVehicleId()
  return mRideAlongVehId
end

function M.onVehicleSwitched(oldId, newId)
  if mRideAlongVehId and (oldId == mRideAlongVehId or newId == mRideAlongVehId) then
    M.endRideAlongSession()
  end
end

function M.onFreeroamSessionStarted(data)
  if type(data) ~= "table" or data.raceName ~= "track" then
    return
  end
  if gameplay_events_freeroam_competitiveTrackFlow and gameplay_events_freeroam_competitiveTrackFlow.isRacingTeamProxyRaceSessionActive and gameplay_events_freeroam_competitiveTrackFlow.isRacingTeamProxyRaceSessionActive() then
    M.beginRideAlongSession(data.subjectID)
  end
end

function M.onFreeroamSessionExiting()
  M.endRideAlongSession()
  M.restorePreRaceWorldState()
end

return M
