local M = {}

function M.build(ctx)
  local raceCommit = {}

  raceCommit.boostPlanSpeeds = function(plan)
    if not (ctx.opt.racing and ctx.parameters.raceCommitCorners ~= false) or not plan then return end
    local mult = (type(ctx.parameters.raceCornerPlanBoost) == 'number' and ctx.parameters.raceCornerPlanBoost) or 1.06
    if mult <= 1.001 then return end
    for i = 1, plan.planCount do
      local n = plan[i]
      if n and type(n.speed) == 'number' and n.speed > 0 and n.speed < 500 then
        n.speed = n.speed * mult
      end
    end
  end

  raceCommit.applySpeedFloor = function(rawTS)
    if not (ctx.opt.racing and ctx.parameters.raceCommitCorners ~= false) then
      return rawTS
    end
    if ctx.ego.speed > 6 and ctx.maxPropWheelSlip() < 0.92 then
      local floorPct = (type(ctx.parameters.raceCommitSpeedFloorPct) == 'number' and ctx.parameters.raceCommitSpeedFloorPct) or 0.98
      rawTS = math.max(rawTS, ctx.ego.speed * floorPct)
    end
    return rawTS
  end

  raceCommit.smoothPlanTargetSpeed = function(rawTS, dt)
    if not (ctx.opt.racing and ctx.parameters.raceCommitCorners ~= false) then
      return ctx.targetSpeedSmoother:get(rawTS, dt)
    end
    local prev = ctx.targetSpeedSmoother:value()
    local baseRate = (type(ctx.parameters.targetSpeedSmootherRate) == 'number' and ctx.parameters.targetSpeedSmootherRate) or 14
    local rate = rawTS > prev and (baseRate * 0.3) or (baseRate * 4.2)
    return ctx.targetSpeedSmoother:getWithRate(rawTS, dt, rate)
  end

  raceCommit.applyCornerExitPush = function(targetSpeed, plan, dt)
    if not (ctx.opt.racing and ctx.parameters.raceCornerExitPush ~= false and plan and plan.originaltargetSpeed and plan[1] and plan[2]) then return targetSpeed end
    if type(targetSpeed) ~= 'number' or type(plan.originaltargetSpeed) ~= 'number' then return targetSpeed end
    if type(plan.trafficTargetSpeed) == 'number' and plan.trafficTargetSpeed < plan.originaltargetSpeed then return targetSpeed end
    local s1, s2 = plan[1].speed, plan[2].speed
    if type(s1) ~= 'number' or type(s2) ~= 'number' then return targetSpeed end
    local minGain = (type(ctx.parameters.raceCornerExitPushMinGain) == 'number' and ctx.parameters.raceCornerExitPushMinGain) or 0.8
    if s2 <= s1 + minGain then return targetSpeed end
    local slipMax = (type(ctx.parameters.raceCornerExitPushSlipMax) == 'number' and ctx.parameters.raceCornerExitPushSlipMax > 0) and ctx.parameters.raceCornerExitPushSlipMax or 0.92
    if ctx.maxPropWheelSlip() >= slipMax or sensors.gz > 0.15 then return targetSpeed end
    local overshoot = (type(ctx.parameters.raceCornerExitPushOvershoot) == 'number' and ctx.parameters.raceCornerExitPushOvershoot > 0) and ctx.parameters.raceCornerExitPushOvershoot or 1.03
    local capTS = math.min(s2, plan.originaltargetSpeed * overshoot)
    if ctx.ego.speed >= capTS - 0.4 or targetSpeed >= capTS - 0.2 then return targetSpeed end
    local rise = (type(ctx.parameters.raceCornerExitPushRiseRate) == 'number' and ctx.parameters.raceCornerExitPushRiseRate > 0) and ctx.parameters.raceCornerExitPushRiseRate or 18
    targetSpeed = math.min(capTS, targetSpeed + rise * dt)
    plan.targetSpeed = targetSpeed
    return targetSpeed
  end

  local function maxPropWheelSlip()
    local propSlip = 0
    local lwheels = wheels.wheels
    for i = 0, tableSizeC(lwheels) - 1 do
      local wd = lwheels[i]
      if wd and not wd.isBroken and wd.isPropulsed then
        propSlip = math.max(propSlip, wd.lastSlip or 0)
      end
    end
    return propSlip
  end
  ctx.maxPropWheelSlip = maxPropWheelSlip

  local function racingPlannerAccelMult()
    if not ctx.opt.racing then return 1 end
    if ctx.parameters.raceCommitCorners == false then
      local s = ctx.parameters.raceAccelScale
      return (type(s) == 'number' and s > 0) and s or 1
    end
    local util = (type(ctx.parameters.raceCornerGripUtil) == 'number' and ctx.parameters.raceCornerGripUtil) or 1.32
    local extra = ctx.parameters.raceAccelScale
    if type(extra) == 'number' and extra > 0 then
      return util * extra
    end
    return util
  end

  return raceCommit, racingPlannerAccelMult, maxPropWheelSlip
end

return M
