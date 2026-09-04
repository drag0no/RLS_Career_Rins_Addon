-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local function destructIfObjectGone(self)
  if not getObjectByID(self.veh.id) then
    gameplay_traffic.removeTraffic(self.veh.id)
    return true
  end
  return false
end

local function isPlayerPoliceUnit(id, veh)
  if not id then return false end
  if veh and veh.role and veh.role.name == 'police' then
    return true
  end
  if veh and veh.ignorePolice then
    return true
  end
  local policeUnits = gameplay_police and gameplay_police.getPoliceVehicles and gameplay_police.getPoliceVehicles()
  if policeUnits and policeUnits[id] then
    return true
  end
  return false
end

local function clearAiChaseTarget(roleSelf)
  if not roleSelf or not roleSelf.veh or not roleSelf.veh.isAi then return end
  local obj = getObjectByID(roleSelf.veh.id)
  if obj then
    obj:queueLuaCommand('ai.setTargetObjectID(-1)')
  end
end

local function shouldIgnoreVehicle(id, veh)
  local obj = getObjectByID(id)
  if not obj then return false end

  -- Never pursue fellow police units (including the player when acting as a cop).
  if isPlayerPoliceUnit(id, veh) then
    return true
  end

  local playerVehicle = be:getPlayerVehicle(0)
  if playerVehicle and id == playerVehicle:getId() then
    if gameplay_ambulance and gameplay_ambulance.isInAmbulance and gameplay_ambulance.isInAmbulance() then
      return true
    end
  end

  if veh and veh.ignorePolice then return true end

  return false
end

local function applyWantedAggression(self, targetVeh)
  if not self.veh.isAi then return end
  local pursuit = targetVeh and targetVeh.pursuit
  local aggression = gameplay_police.getPursuitAggression and gameplay_police.getPursuitAggression(pursuit) or 0.7
  -- ignorePersonality so wanted curve is the authority (setAiMode('chase') would otherwise floor at 0.8).
  self:setAggression(aggression, true)

  local crashSpeed = gameplay_police.getPursuitCrashSpeed and gameplay_police.getPursuitCrashSpeed(pursuit) or 10
  local obj = getObjectByID(self.veh.id)
  if obj then
    obj:queueLuaCommand(string.format('ai.setParameters({chaseCrashSpeed=%.3f})', crashSpeed))
  end
end

function C:init()
  self.class = 'emergency'
  self.keepActionOnRefresh = false
  self.personalityModifiers = {
    aggression = {offset = 0.1}
  }
  self.veh.drivability = 0.5
  self.targetPursuitMode = 0
  self.targetLastState = 'none'
  self.avoidSpeed = 40 -- speed difference at which the police vehicle will try to dodge the target vehicle
  self.sirenTimer = -1
  self.cooldownTimer = -1
  self.aggressionRefreshTimer = 0
  self.driveInLane = true
  self.validTargets = {}
  self.actions = {
    pursuitStart = function (args)
      if destructIfObjectGone(self) then return end
      local firstMode = 'chase'
      local modeNum = 0
      local obj = getObjectByID(self.veh.id)
      local targetVeh

      if self.veh.isAi then
        obj:queueLuaCommand('ai.setSpeedMode("off")')
        obj:queueLuaCommand('ai.driveInLane("on")')

        if args.targetId then
          targetVeh = gameplay_traffic.getTrafficData()[args.targetId]
          if targetVeh then
            modeNum = targetVeh.pursuit.mode
            firstMode = modeNum <= 1 and 'follow' or 'chase'
          end
        end

        if modeNum == 1 then -- passive
          self.veh:setAiMode('follow')
          self.veh:useSiren(0.5 + math.random())
          self.sirenTimer = 2 + math.random() * 2
        else -- aggressive
          self.veh:setAiMode('chase')
          obj:queueLuaCommand('electrics.set_lightbar_signal(2)')
          self.sirenTimer = -1
        end
        applyWantedAggression(self, targetVeh)
      end

      self.targetPursuitMode = modeNum
      self.state = firstMode
      self.driveInLane = true
      self.flags.roadblock = nil
      self.flags.busy = 1
      self.cooldownTimer = -1
      self.aggressionRefreshTimer = 0
      self.avoidSpeed = math.max(40, math.random(18, 24) * modeNum)

      if not self.flags.pursuit then
        self.veh:modifyRespawnValues(500)
        self.flags.pursuit = 1
      end
    end,
    pursuitEnd = function ()
      if self.veh.isAi then
        self.veh:setAiMode('stop')
        if destructIfObjectGone(self) then return end
        getObjectByID(self.veh.id):queueLuaCommand('electrics.set_lightbar_signal(1)')
        self:setAggression()
        clearAiChaseTarget(self)
      end
      self.flags.pursuit = nil
      self.flags.reset = 1
      self.flags.cooldown = 1
      self.cooldownTimer = math.max(10, gameplay_police.getPursuitVars().arrestTime + 5)
      self.state = 'disabled'
      self.aggressionRefreshTimer = 0
      self.targetId = nil

      self.targetPursuitMode = 0
    end,
    chaseTarget = function ()
      self.veh:setAiMode('chase')
      if destructIfObjectGone(self) then return end
      getObjectByID(self.veh.id):queueLuaCommand('ai.driveInLane("off")')
      self.driveInLane = false
      self.state = 'chase'
      local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
      applyWantedAggression(self, targetVeh)
    end,
    avoidTarget = function ()
      self.veh:setAiMode('flee')
      if destructIfObjectGone(self) then return end
      getObjectByID(self.veh.id):queueLuaCommand('ai.driveInLane("on")')
      self.driveInLane = true
      self.state = 'flee'
    end,
    roadblock = function ()
      if self.veh.isAi then
        self.veh:setAiMode('stop')
        if destructIfObjectGone(self) then return end
        getObjectByID(self.veh.id):queueLuaCommand('electrics.set_lightbar_signal(2)')
      end
      self.flags.roadblock = 1
      self.state = 'stop'
      self.veh:modifyRespawnValues(300, 40)
    end
  }

  for k, v in pairs(self.baseActions) do
    self.actions[k] = v
  end
  self.baseActions = nil
end

function C:checkTarget()
  local traffic = gameplay_traffic.getTrafficData()
  local targetId
  local bestScore = 0

  for id, veh in pairs(traffic) do
    if shouldIgnoreVehicle(id, veh) then goto continue end
    if id ~= self.veh.id and veh.role.name ~= 'police' then
      if veh.pursuit.mode >= 1 and veh.pursuit.score > bestScore then
        bestScore = veh.pursuit.score
        targetId = id
      end
    end
    ::continue::
  end

  return targetId
end

function C:resetAction()
  -- Same as baseRole.resetAction, plus clear the vehicle-AI chase target so units
  -- cannot keep chasing (or fall back onto the player cop) after a pursuit ends.
  clearAiChaseTarget(self)
  if self.lockAction then return end
  if self.veh.isAi then
    self.veh:setAiMode()
    self.veh:setAiParameters()
    self.veh:resetElectrics()
  end
  table.clear(self.flags)
  self.state = 'none'
  self.actionName = 'none'
  self.targetId = nil
  self.mapTarget = nil
end

function C:onRefresh()
  if destructIfObjectGone(self) then return end
  if self.state == 'disabled' then self.state = 'none' end
  self.actionTimer = 0
  self.cooldownTimer = -1

  if self.flags.reset then
    self:resetAction()
  end

  local targetId = self:checkTarget()
  if targetId then
    self:setTarget(targetId)
    self.flags.targetVisible = nil
    self:setAction('pursuitStart', {targetId = targetId})
    self.veh:modifyRespawnValues(750 - self.targetPursuitMode * 150)
    if targetId == be:getPlayerVehicleID(0) and gameplay_traffic.getTrafficData()[targetId].pursuit.mode <= 0 then
      log('D', 'police', 'Pursuit started with player vehicle as target, but not triggered correctly!')
    end
  else
    if self.flags.pursuit then
      self:resetAction() -- cancels the pursuit
    elseif self.veh.isAi and not self.flags.busy and not self.flags.driveCheck and not self.flags.roadblock then
      -- keepActionOnRefresh skips vehicle-level resetAction; restore traffic AI so ambient cops drive.
      self.veh:setAiMode()
      self.state = 'none'
    end
  end

  if self.flags.pursuit then
    self.veh.respawn.spawnRandomization = 0.25
  end
end

function C:onTrafficTick(dt)
  if destructIfObjectGone(self) then return end
  local baseValues = gameplay_traffic_trafficUtils.getBaseValues()

  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    if shouldIgnoreVehicle(id, veh) then
      self.validTargets[id] = nil
      goto continue
    end

    if id ~= self.veh.id and veh.role.name ~= 'police' and not self.flags.cooldown then
      if not self.validTargets[id] then self.validTargets[id] = {} end
      local interDist = self.veh:getInteractiveDistance(veh.pos, true)

      self.validTargets[id].dist = self.veh.pos:squaredDistance(veh.pos)
      self.validTargets[id].interDist = interDist
      self.validTargets[id].visible = interDist <= 10000 and self:checkTargetVisible(id)

      if self.flags.pursuit and self.validTargets[id].dist <= 100 and self.veh.speed < baseValues.lowSpeed and veh.speed < baseValues.lowSpeed then
        self.validTargets[id].visible = true
      end

      if self.flags.pursuit and self.validTargets[id].visible and not self.flags.targetVisible then
        local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
        if targetVeh then
          targetVeh.pursuit.policeCount = targetVeh.pursuit.policeCount + 1
          self.flags.targetVisible = 1
        end
      end
    else
      self.validTargets[id] = nil
    end
    ::continue::
  end

  local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
  if self.veh.isAi and targetVeh and self.state ~= 'disabled' and self.veh.state == 'active' then
    if self.flags.pursuit then
      if self.driveInLane and self.state ~= 'flee' and (self.veh.speed <= 1 or self.flags.targetVisible) then
        getObjectByID(self.veh.id):queueLuaCommand('ai.driveInLane("off")')
        self.driveInLane = false
      end

      local targetData = self.validTargets[self.targetId]
      if targetData and targetData.interDist <= 2500 then
        self.avoidSpeed = self.avoidSpeed or 40
        if self.veh.speed >= 8 and targetVeh.speed >= 8 and self.veh.speed + targetVeh.speed >= self.avoidSpeed
        and targetVeh.driveVec:dot(self.veh.driveVec) <= -0.707 and (targetVeh.pos - self.veh.pos):normalized():dot(self.veh.driveVec) >= 0.707 then
          if self.state == 'chase' then
            self:setAction('avoidTarget')
            self.actionTimer = 3
          end
        end
      end
    end

    if self.veh.damage > baseValues.highDamage then
      if self.flags.pursuit and self.veh.pos:squaredDistance(targetVeh.pos) <= 400 then
        targetVeh.pursuit.policeWrecks = targetVeh.pursuit.policeWrecks + 1
      end
      self:setAction('disabled')
      -- Clear pursuit keep-alive so wrecks can leave the active bubble once far enough.
      self.flags.pursuit = nil
      if self.veh.respawn then
        self.veh.respawn.activeRadius = math.min(self.veh.respawn.activeRadius or 160, 160)
        self.veh.respawn.innerRadius = math.min(self.veh.respawn.innerRadius or 50, 50)
        self.veh.respawn.finalRadius = math.min(self.veh.respawn.finalRadius or 160, 160)
      end
    end
  end

  if self.enableTrafficSignalsChange and self.veh.speed >= 6 and next(map.objects[self.veh.id].states) then
    if map.objects[self.veh.id].states.lightbar then
      self:freezeTrafficSignals(true)
    else
      if self.flags.freezeSignals then
        self:freezeTrafficSignals(false)
      end
    end
  else
    if self.flags.freezeSignals then
      self:freezeTrafficSignals(false)
    end
  end
end

function C:onUpdate(dt, dtSim)
  if destructIfObjectGone(self) then return end
  local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
  local baseValues = gameplay_traffic_trafficUtils.getBaseValues()

  if self.veh.isAi and self.state ~= 'disabled' and self.sirenTimer ~= -1 then
    if self.sirenTimer <= 0 then
      if self.flags.pursuit and targetVeh and targetVeh.pursuit.mode >= 1 then
        local minSpeed = targetVeh.pursuit.initialSpeed or 0
        if targetVeh.pursuit.timers.main >= 8 or targetVeh.speed >= minSpeed + 5 then
          getObjectByID(self.veh.id):queueLuaCommand('electrics.set_lightbar_signal(2)')
          self.sirenTimer = -1
        else
          if targetVeh.speed >= baseValues.lowSpeed then
            self.veh:useSiren(0.5 + math.random())
            self.sirenTimer = 2 + math.random() * 2
          end
        end
      else
        self.sirenTimer = -1
      end
    else
      self.sirenTimer = self.sirenTimer - dt
    end
  end

  if self.cooldownTimer <= 0 then
    if self.cooldownTimer ~= -1 then
      self:onRefresh()
    end
  else
    self.flags.cooldown = 1
    self.cooldownTimer = self.cooldownTimer - dt
  end

  if not self.flags.pursuit or self.state == 'none' or self.state == 'disabled' then return end
  if not targetVeh or (targetVeh and not targetVeh.role.flags.flee) then
    self:resetAction()
    return
  end

  if self.veh.isAi then
    self.targetPursuitMode = targetVeh.pursuit.mode or self.targetPursuitMode
    self.aggressionRefreshTimer = (self.aggressionRefreshTimer or 0) - dtSim
    if self.aggressionRefreshTimer <= 0 then
      applyWantedAggression(self, targetVeh)
      self.aggressionRefreshTimer = 1.0
    end

    local distSq = self.veh.pos:squaredDistance(targetVeh.pos)
    local brakeDistSq = square(self.veh:getBrakingDistance(self.veh.speed, 1) + 20)
    local targetVisible = self.validTargets[self.targetId or 0] and self.validTargets[self.targetId].visible

    if self.actionTimer > 0 then
      self.actionTimer = self.actionTimer - dtSim
    end

    if self.flags.pursuit and self.state ~= 'none' and self.state ~= 'disabled' and self.veh.vars.aiMode == 'traffic' then
      if self.flags.roadblock then
        if targetVeh.pursuit.timers.evadeValue >= 0.5 or not targetVeh.pursuit.roadblockPos
        or targetVeh.vel:dot((targetVeh.pos - targetVeh.pursuit.roadblockPos):normalized()) >= 9 then
          self:setAction('chaseTarget')
          self.flags.roadblock = nil
        end
      else
        local minSpeed = (4 - self.targetPursuitMode) * 3
        if self.targetPursuitMode < 3 and targetVisible and targetVeh.speed <= minSpeed and self.veh.speed >= 8 then
          if self.state == 'chase' and distSq <= brakeDistSq and targetVeh.driveVec:dot(targetVeh.pos - self.veh.pos) > 0 then
            self:setAction('pullOver')
            self.actionTimer = gameplay_police.getPursuitVars().arrestTime + 5
          end
        else
          if self.state == 'pullOver' and (not targetVisible or targetVeh.speed > minSpeed) then
            self.actionTimer = 0
          end
        end

        if (self.state == 'flee' or self.state == 'pullOver') and self.actionTimer <= 0 then
          self:setAction('chaseTarget')
        end
      end
    end
  end
end

return function(...) return require('/lua/ge/extensions/gameplay/traffic/baseRole')(C, ...) end
