-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min, max, abs = math.min, math.max, math.abs
local sin, cos, exp = math.sin, math.cos, math.exp

local manualzoom = require('core/cameraModes/manualzoom')

-- playerController: walk 1.8 m/s, sprint 5 m/s
local bobScale = 0.5
local walkSpeed = 1.8
local sprintSpeed = 5.0
local downVec = vec3(0, 0, -1)
local groundProbe = vec3()

local C = {}
C.__index = C

local function smoothApproach(current, target, dt, rate)
  return current + (target - current) * (1 - exp(-dt * rate))
end

local function isBobEnabled()
  local s = rawget(_G, "overhaul_settings")
  if s and s.getSetting then
    return s.getSetting("realisticWalkingCamera") ~= false
  end
  return true
end

local function rotateEuler(x, y, z, q)
  q = q or quat()
  q = quatFromEuler(0, z, 0) * q
  q = quatFromEuler(0, 0, x) * q
  q = quatFromEuler(y, 0, 0) * q
  return q
end

function C:init()
  self.hidden = true
  self.canUseVehicleTriggerCrosshair = true
  self.zoomSmoother = newTemporalSmoothing(20)
  self.bobPhase = 0
  self.bobT = 0
  self.bobPhaseVec = vec3(math.random(), math.random(), math.random()) * (2 * math.pi)
  self.walkAmtSmooth = 0
  self.sprintAmtSmooth = 0
  self.climbAmtSmooth = 0
  self.groundedBlend = 1
  self.wasGrounded = true
  self.landDip = 0
  self.jumpPitch = 0
  self.prevVz = 0
  self.prevGroundZ = nil
  self.scriptedTransition = nil
  self:onSettingsChanged()
  self:reset()
end

function C:onSettingsChanged()
  self.openXRsnapTurnUnicycle = settings.getValue('openXRsnapTurnUnicycle')
  self.openXRsnapTurnUnicycleDegrees = settings.getValue('openXRsnapTurnUnicycleDegrees')
end

function C:onCameraChanged(focused)
  local isUnicycle = not activeGlobalCameraName and core_vehicle_manager and core_vehicle_manager.getPlayerVehicleData() and core_vehicle_manager.getPlayerVehicleData().mainPartName == "unicycle"
  if isUnicycle then return end

  if focused then
    if not self.pos or not self.rotVec then
      log("E", "", "No original pos,rotVec was provided (e.g. via setCustomData)")
    end
    guihooks.trigger('appContainer:loadLayoutByType', "unicycle")
  else
    core_gamestate.requestGameState() -- this is the best way i know of to go back to the intended ui layout, but i don't know if it's really right.
  end
end

function C:reset()
  --TODO what should reset do?
  self.zoomSmoother:reset()
  --self.pos = nil
  --self.rotVec = nil
end

-- return the point where we hit something on the way from origin to target
-- if nothing is hit, return nil
local function castRayLocation(origin, target)
  local result = vec3()
  local dir = target-origin
  local dist = dir:length()
  local ret = castRayStatic(origin, dir, dist)
  if ret >= dist then return end -- default to zero distance from origin
  result = origin + (dir:normalized()*ret)
  return result
end

local humanHeight = 1.6
local function getHumanHeight(crouching)
  return humanHeight * (crouching and 0.7 or 1)
end
local function getHipHeight(crouching)
  return getHumanHeight(crouching) * 0.45
end
local function getEyePosition(pos)
  local result
  local resultUp = pos+vec3(0, 0, getHipHeight(crouching))
  local resultDown = pos+vec3(0, 0,-5)
  local resultGround = castRayLocation(resultUp, resultDown)
  if resultGround then
    result = resultGround + vec3(0,0,getHumanHeight())
  else
    result = pos
  end
  return result
end

local prevCamPos
local maxFallHeight = 10
local gravity = -2
local teleportingSpeed = 1000/3.6 -- in m/s, threshold to detect teleport with F7 / recovery / reset / replay seeking
local function attemptToWalk(camPos, dt, crouching)
  if not levelLoaded then return camPos end -- don't attempt to walk if no level is loaded, as we can't raycast or do anything useful
  -- keep player walking on the ground
  local cameraTeleported = prevCamPos and (prevCamPos:distance(camPos)/dt > teleportingSpeed)
  if cameraTeleported then prevCamPos = nil end
  if prevCamPos then camPos.z = prevCamPos.z end
  local oldGround = camPos+vec3(0, 0, -getHumanHeight(crouching))
  local hip = oldGround+vec3(0, 0, getHipHeight(crouching))
  local target = oldGround+vec3(0, 0, -maxFallHeight)
  local newGround = castRayLocation(hip, target)
  local newCamPos
  -- calculate potential future location
  if newGround then
    -- found ground within the fall height
    if newGround.z < oldGround.z then
      --dump("ground known, falling towards it")
      newGround.z = max(oldGround.z + gravity*dt, newGround.z)
      newCamPos = newGround + vec3(0,0,getHumanHeight(crouching))
    else
      --dump("ground known, immediately climbing it")
      newCamPos = newGround + vec3(0,0,getHumanHeight(crouching))
    end
  else
    -- didn't find any ground within the fall height
    if prevCamPos then
      --dump("ground unknown, reverting")
      --newCamPos = prevCamPos
      newCamPos = camPos + vec3(0,0, gravity*dt)
    else
      --dump("ground unknown, falling into the abyss?")
      newCamPos = camPos + vec3(0,0, gravity*dt)
    end
  end
  -- check if we can get to the new potential location without hitting something
  if prevCamPos then
    local newKnee = newCamPos+vec3(0,0, -getHumanHeight(crouching)+getHipHeight(crouching))
    local prevKnee = prevCamPos+vec3(0,0, -getHumanHeight(crouching)+getHipHeight(crouching))
    local hipCollisionPoint = castRayLocation(prevKnee, newKnee)
    if hipCollisionPoint then
      -- our head hit something, stay away from the collision
      local diff = prevKnee - hipCollisionPoint
      local dist = max(diff:length(), 0.3) -- stay some distance away from collision point
      hipCollisionPoint = hipCollisionPoint + diff:normalized()*dist -- stay 20cm away from collision point
      newKnee = vec3(hipCollisionPoint.x, hipCollisionPoint.y, newKnee.z)
      newCamPos = newKnee+vec3(0,0,-getHipHeight(crouching)+getHumanHeight(crouching))
      --newCamPos = prevCamPos
    else
      -- no collision, all good
    end
  end
  prevCamPos = newCamPos
  return newCamPos
end

local function getRotVecFromFrontUp(front, up)
  local initialLookDir = quatFromDir(front, up or vec3(0, 0, 1))
  local rotEuler = initialLookDir:toEulerYXZ()
  local pitch = clamp(math.deg(rotEuler.y), -89.9, 89.9)
  return vec3(math.deg(rotEuler.x), 180 - pitch, 0)
end

function C:setCustomData(customData)
  --TODO teleport vehicle to new position
  customData = customData or {}
  if customData.pos then
    self.pos = getEyePosition(customData.pos)
  end
  if customData.front then
    self.rotVec = getRotVecFromFrontUp(customData.front, customData.up)
  end
end

-- Small first-person offsets used by the realistic vehicle entry/exit sequence.
-- They are visual-only: the clean horizontal rotation below still drives walking.
function C:setScriptedTransition(data)
  self.scriptedTransition = data
end

function C:getPosRot()
  if not self.pos or not self.rotVec then
    log("W", "", "Unicycle camera cannot provide a position or a rotation: "..dumps(self.pos).." / "..dumps(self.rotVec))
    return vec3(), quat()
  end
  local rot = rotateEuler(-math.rad(self.rotVec.x), -math.rad(self.rotVec.y), math.rad(self.rotVec.z))
  return self.pos, rot
end

local function isRadialMenuOpen()
  return core_quickAccess and core_quickAccess.isEnabled and core_quickAccess.isEnabled() or false
end

function C:update(data)
  local dt = data.dtSim
  -- Guard against near-zero dtSim (menu open / hitch) blowing up climbRate and bob.
  local dtSafe = max(dt, 1 / 120)
  local radialOpen = isRadialMenuOpen()
  if not self.rotVec then
    local veh = getPlayerVehicle(0)
    self:setCustomData({pos=data.pos, front=veh:getDirectionVector(), up=veh:getDirectionVectorUp()})
  end
  --if self.pos == nil then
    --log("E", "", "Walk camera has no usable pos data")
    --return
  --end

  -- zoom
  local zoomValue = self.zoomSmoother:get(data.unicycleZoom or 0, dtSafe)
  data.res.fov = zoomValue * 27 + (1 - zoomValue) * 55

  -- rotation
  -- While radial is open, ignore relative mouse/stick look so selection input
  -- doesn't fight the walking camera (causes high-frequency shake).
  local lookScale = (1 - zoomValue * 0.88) * 20 * dtSafe
  local rdx = lookScale * (MoveManager.yawRight - MoveManager.yawLeft)
  local rdyNotMouse = lookScale * (MoveManager.pitchUp - MoveManager.pitchDown)
  local rdy = rdyNotMouse
  if not radialOpen then
    rdx = MoveManager.yawRelative + rdx
    rdy = MoveManager.pitchRelative + rdyNotMouse
  end
  if data.openxrSessionRunning and self.openXRsnapTurnUnicycle then
    local mustTurn = false
    self.lastSnapTurn = self.lastSnapTurn or 0

    -- check if we need to trigger a turn event
    if rdx ~= 0 and (self.rdxLast or 0) == 0 then
      -- user just started pressing a button or analog stick
      self.lastSnapTurn = os.clock()
      mustTurn = true
    end
    if sign(rdx) ~= sign(self.rdxLast or 0) then
      -- user has switched direction of button or analog stick
      self.lastSnapTurn = os.clock()
      mustTurn = true
    end
    if rdx ~= 0 then
      -- user has held button or analog stick for more than an instant, so we can re-trigger a turn
      local snapTurnPeriod = 0.4
      if os.clock()-self.lastSnapTurn > snapTurnPeriod then
        self.lastSnapTurn = self.lastSnapTurn + snapTurnPeriod
        mustTurn = true
      end
    end

    -- perform the sudden turn, following the user preference
    if mustTurn then
      self.rotVec.x = self.rotVec.x + sign(rdx) * self.openXRsnapTurnUnicycleDegrees
    end
    self.rdxLast = rdx
  else
    self.rotVec = self.rotVec + (dt>0 and 7 or 0)*vec3(rdx, rdy, 0)
    self.rotVec.y = clamp(self.rotVec.y, 180-89.9, 180+89.9) -- limit head pitch, look at floor or roof, but not further than that (adding a 0.1 safety margin to account for float precission issues in later conversions)
  end
  if data.openxrSessionRunning then
    self.rotVec.y = 180 -- remove manual head tilt

    -- reinterpret "tilt-down" as trigger to rotate 180 degrees
    -- we exclude mouse values (mouse movement is based on pixels, not a normalized 0..1 amount, so we cannot meaningfully detect "big mouse movement down")
    if rdyNotMouse < -0.15 and (self.rdyNotMouseLast or 0) >= -0.15 then
      self.rotVec.x = self.rotVec.x + 180
    end
    self.rdyNotMouseLast = rdyNotMouse
  else
  end
  if data.openxrSessionRunning then
  end

  local rot = rotateEuler(-math.rad(self.rotVec.x), -math.rad(self.rotVec.y), math.rad(self.rotVec.z))
  local rotHorizontal = rotateEuler(-math.rad(self.rotVec.x), -math.rad(180), math.rad(self.rotVec.z))

  local camNodeID = core_camera.getDriverData(data.veh)
  local nodePos = vec3(data.veh:getNodePosition(camNodeID or 0))
  local carPos = data.pos
  self.pos = carPos + nodePos

  -- application (visual bob/sway only — rotHorizontal stays clean for vehicle steering)
  local bobUp, swayPitch, swayRoll, swayYaw = 0, 0, 0, 0
  local bobEnabled = isBobEnabled()
  -- Freeze bob/sway while radial is open or bob is disabled; decay motion so re-enable is clean.
  if not data.openxrSessionRunning and dt > 0 then
    if radialOpen or not bobEnabled then
      self.walkAmtSmooth = smoothApproach(self.walkAmtSmooth, 0, dtSafe, 20)
      self.sprintAmtSmooth = smoothApproach(self.sprintAmtSmooth, 0, dtSafe, 20)
      self.climbAmtSmooth = smoothApproach(self.climbAmtSmooth, 0, dtSafe, 20)
      self.landDip = self.landDip * exp(-dtSafe * 16)
      self.jumpPitch = smoothApproach(self.jumpPitch, 0, dtSafe, 20)
      self.prevGroundZ = nil
    else
    local vel = data.veh:getVelocity()
    local horizSpeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
    local vz = vel.z

    groundProbe:set(self.pos.x, self.pos.y, self.pos.z)
    local groundDist = castRayStatic(groundProbe, downVec, humanHeight + 0.8)
    local nearGround = groundDist < (humanHeight + 0.35)
    local grounded = nearGround and vz < 2.2
    self.groundedBlend = smoothApproach(self.groundedBlend, grounded and 1 or 0, dtSafe, grounded and 14 or 6)

    local groundZ = self.pos.z - groundDist
    local climbRate = 0
    if self.prevGroundZ and grounded then
      climbRate = clamp((groundZ - self.prevGroundZ) / dtSafe, -3, 3)
    end
    if grounded then
      self.prevGroundZ = groundZ
    else
      self.prevGroundZ = nil
    end

    if grounded and not self.wasGrounded then
      local impact = min(max(-self.prevVz, 0) / 8, 1)
      self.landDip = max(self.landDip, 0.004 + 0.010 * impact)
    end
    self.wasGrounded = grounded
    self.prevVz = vz
    self.landDip = self.landDip * exp(-dtSafe * 16)

    local jumpPitchTarget = 0
    if self.groundedBlend < 0.85 then
      jumpPitchTarget = clamp(vz * 0.004, -0.015, 0.015)
    end
    self.jumpPitch = smoothApproach(self.jumpPitch, jumpPitchTarget, dtSafe, 14)
    self.jumpPitch = self.jumpPitch - self.landDip * 0.25

    local walkTarget, sprintTarget = 0, 0
    if horizSpeed > 0.15 then
      walkTarget = min(horizSpeed / walkSpeed, 1)
      sprintTarget = clamp((horizSpeed - walkSpeed) / (sprintSpeed - walkSpeed), 0, 1)
    end
    walkTarget = walkTarget * self.groundedBlend
    sprintTarget = sprintTarget * self.groundedBlend
    self.walkAmtSmooth = smoothApproach(self.walkAmtSmooth, walkTarget, dtSafe, 10)
    self.sprintAmtSmooth = smoothApproach(self.sprintAmtSmooth, sprintTarget, dtSafe, 8)

    local walkAmt = self.walkAmtSmooth
    local sprintAmt = self.sprintAmtSmooth
    local moveAmt = max(walkAmt, sprintAmt)

    -- climbing stairs / steep rise: rising ground underfoot while moving
    local climbTarget = 0
    if moveAmt > 0.2 and climbRate > 0.18 then
      climbTarget = clamp((climbRate - 0.18) / 0.75, 0, 1) * self.groundedBlend
    end
    self.climbAmtSmooth = smoothApproach(self.climbAmtSmooth, climbTarget, dtSafe, 7)
    local climbAmt = self.climbAmtSmooth

    -- walk/sprint amts both hit 1 when running — blend cadence, don't stack
    -- stairs: slower, heavier steps
    local bobRate = (5.8 + 0.9 * sprintAmt) * moveAmt * (1 - 0.40 * climbAmt)
    self.bobT = self.bobT + dtSafe
    self.bobPhase = self.bobPhase + dtSafe * bobRate

    local foot = sin(self.bobPhase)
    local plant = abs(foot)
    plant = plant * plant
    local stepLift = 0.5 * (1 - cos(self.bobPhase * 2))

    local stepAmp = bobScale * (0.034 * walkAmt + 0.022 * sprintAmt)
    bobUp = (stepLift * stepAmp * 0.55 - plant * stepAmp * 0.45) * self.groundedBlend
    -- stair heave: lift onto the tread, then settle on the plant
    if climbAmt > 0.01 then
      local stairAmp = bobScale * 0.055 * climbAmt * moveAmt
      bobUp = bobUp + stepLift * stairAmp * 0.85 - plant * stairAmp * 0.65
    end
    bobUp = bobUp - self.landDip

    local var = bobScale * (1 - 0.82 * sprintAmt) * (0.4 + 0.6 * self.groundedBlend)
    local t, ph = self.bobT, self.bobPhaseVec
    swayPitch = var * 0.014 * walkAmt * sin(self.bobPhase * 2)
      + var * 0.003 * (1 - sprintAmt) * sin(0.7 * t + ph.y)
      + self.jumpPitch
      + climbAmt * (0.018 + 0.022 * plant) -- glance down at each stair plant
    swayRoll = var * 0.020 * walkAmt * foot * (1 - 0.65 * sprintAmt)
      + var * 0.004 * (1 - sprintAmt) * sin(0.45 * t + ph.z)
      + climbAmt * 0.012 * foot * moveAmt
    swayYaw = var * 0.006 * walkAmt * sin(self.bobPhase + 0.8) * (1 - 0.75 * sprintAmt)
      + var * 0.003 * (1 - sprintAmt) * sin(0.55 * t + ph.x)

    local still = (1 - moveAmt) * bobScale * self.groundedBlend
    if still > 0.01 then
      local breath = sin(t * 1.15 + ph.x)
      bobUp = bobUp + still * 0.010 * breath
      swayPitch = swayPitch + still * 0.008 * breath
      swayYaw = swayYaw + still * 0.006 * sin(t * 0.55 + ph.z)
    end

    rot = rot * quatFromEuler(swayPitch, swayRoll, swayYaw)
    end
  end

  local transitionOffset = vec3(0, 0, bobUp)
  local scripted = self.scriptedTransition
  if scripted and not data.openxrSessionRunning then
    local localOffset = vec3(scripted.side or 0, scripted.forward or 0, scripted.z or 0)
    transitionOffset:setAdd(rot * localOffset)
    transitionOffset:setAdd(vec3(scripted.worldX or 0, scripted.worldY or 0, scripted.worldZ or 0))
    rot = rot * quatFromEuler(scripted.pitch or 0, scripted.roll or 0, scripted.yaw or 0)
  end
  data.res.pos:set(self.pos.x + transitionOffset.x, self.pos.y + transitionOffset.y, self.pos.z + transitionOffset.z)
  data.res.rot = rot

  -- unicycle guiding
  data.veh:queueLuaCommand("controller.getControllerSafe('playerController').setCameraControlData("..serialize({cameraRotation = rotHorizontal})..")")
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
