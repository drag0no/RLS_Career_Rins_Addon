local M = {}

local destination = nil

local drivability = 0
local dirMult = 10000
local penaltyAboveCutoff = 1000
local penaltyBelowCutoff = 100000
local wZ = 1
local exactPathReleaseTimer = 0

local function onExtensionLoaded()
    if not mapmgr.mapData then
        mapmgr.requestMap()
    end
end

local function updateGFX(dt)
    if exactPathReleaseTimer <= 0 then
        return
    end

    exactPathReleaseTimer = math.max(0, exactPathReleaseTimer - (dt or 0))
    -- Scripted-path initialization performs an internal position reset. Some
    -- automatic configurations reapply their parking brake or drop ignition
    -- during that reset, after driveExactPath's first release command.
    if electrics and electrics.setIgnitionLevel then
        electrics.setIgnitionLevel(3)
    end
    input.event("parkingbrake", 0, 1)
end

-- Stop the post-exact-path ignition/PB release assist (auction arrive hold).
local function cancelExactPathAssist()
    exactPathReleaseTimer = 0
end

local function goToTarget(speedMode, noTraffic)
    local path = mapmgr.getPointToPointPath(
        obj:getPosition(),
        destination,
        drivability,
        dirMult,
        penaltyAboveCutoff,
        penaltyBelowCutoff,
        wZ
    )
    print("[driver] goToTarget: path=" .. tostring(path) .. " len=" .. (path and #path or 0))
    table.remove(path, 1)
    ai.setPath(path)
    if noTraffic then
        ai.driveUsingPath({
            wpTargetList = path,
            avoidCars = "on",
            driveInLane = "on",
            routeSpeedMode = speedMode or 'legal'
        })
        ai.setParameters({
            lookAheadKv = 0.03,
            awarenessForceCoef = 0.1,
        })
    else
        ai.driveUsingPathWithTraffic({
            wpTargetList = path,
            routeSpeedMode = speedMode or 'legal'
        })
        ai.setParameters({
            trafficWaitTime = 0.005,
            lookAheadKv = 0.01,
            awarenessForceCoef = 0.02, 
            driveStyle = "offroad"
        })
    end
end

local function raceToTarget()
    local path = mapmgr.getPointToPointPath(
        obj:getPosition(),
        destination,
        drivability,
        dirMult,
        penaltyAboveCutoff,
        penaltyBelowCutoff,
        wZ
    )
    table.remove(path, 1)
    ai.setPath(path)
    ai.setMode("manual")
    ai.setAvoidCars("on")
    ai.setSpeedMode("off")
    ai.driveInLane("on")
    ai.setParameters({
        lookAheadKv = 0.03,
        awarenessForceCoef = 0.1,
    })
end

local function returnTargetPosition(target, race, speedMode, noTraffic)
    destination = target
    if race then
        raceToTarget()
    else
        goToTarget(speedMode, noTraffic)
    end
end

-- Follow a free-form trajectory and cross an exact vehicle-origin target.
--
-- ai.driveUsingPath's script coordinates describe obj:getFrontPosition(), not
-- obj:getPosition(). The original front reference can also have a lateral
-- offset (for example, the D-Series box truck is 0.55 m off-center). Convert
-- the requested final vehicle transform into the corresponding front-reference
-- trajectory so every body length and reference-node layout stops in the same
-- designated spot.
local function driveExactPath(routePoints, target, targetDir, options)
    if type(routePoints) ~= "table" or not target or not targetDir then
        return false
    end

    options = type(options) == "table" and options or {}
    local routeSpeed = tonumber(options.routeSpeed) or 4.4352
    local pathRadius = math.max(0.05, tonumber(options.pathRadius) or 0.1)
    local terminalStartDistance = tonumber(options.terminalStartDistance) or 15
    local aggression = tonumber(options.aggression) or 0.3

    local targetPos = vec3(target)
    local finalDir = vec3(targetDir):z0()
    if finalDir:squaredLength() < 0.01 then
        return false
    end
    finalDir:normalize()

    local finalUp = options.targetUp and vec3(options.targetUp) or vec3(0, 0, 1)
    finalUp:normalize()

    local frontRel = obj:getOriginalFrontPositionRelative()
    local frontOffset =
        finalDir * (-frontRel.y) +
        finalUp * frontRel.z +
        finalDir:cross(finalUp) * (-frontRel.x)

    local currentFront = obj:getFrontPosition()
    local currentDir = obj:getDirectionVector()
    local currentUp = obj:getDirectionVectorUp()
    local script = {
        {
            x = currentFront.x,
            y = currentFront.y,
            z = currentFront.z,
            dir = {x = currentDir.x, y = currentDir.y, z = currentDir.z},
            up = {x = currentUp.x, y = currentUp.y, z = currentUp.z},
            r = pathRadius
        }
    }

    for _, routePoint in ipairs(routePoints) do
        local point = vec3(routePoint)
        if point:distance(targetPos) > terminalStartDistance then
            table.insert(script, {
                x = point.x,
                y = point.y,
                z = point.z,
                r = pathRadius,
                v = tonumber(routePoint.v)
            })
        end
    end

    local approach = options.approach or {
        {distance = 15, speed = 2.2},
        {distance = 9, speed = 1.5},
        {distance = 4, speed = 0.9},
        -- Cross the designated origin at walking speed. The game-engine
        -- auction update freezes the vehicle on this point.
        {distance = 0, speed = 0.45},
        -- Give the AI a braking point beyond the mark so it does not perform
        -- its conservative stop before reaching the actual parking position.
        {distance = -2, speed = 0}
    }

    for _, approachPoint in ipairs(approach) do
        local distance = tonumber(approachPoint.distance) or 0
        local point = targetPos - finalDir * distance + frontOffset
        table.insert(script, {
            x = point.x,
            y = point.y,
            z = point.z,
            r = pathRadius,
            v = tonumber(approachPoint.speed)
        })
    end

    if #script < 3 then
        return false
    end

    if electrics and electrics.setIgnitionLevel then
        electrics.setIgnitionLevel(3)
    end
    input.event("brake", 0, 1)
    input.event("parkingbrake", 0, 1)
    ai.driveUsingPath({
        script = script,
        routeSpeed = routeSpeed,
        routeSpeedMode = "limit",
        aggression = aggression,
        avoidCars = options.avoidCars or "off"
    })
    exactPathReleaseTimer = 1
    return true
end

local function driveToTarget(drivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wZ)
    drivability = drivability or 0
    dirMult = dirMult or 10000
    penaltyAboveCutoff = penaltyAboveCutoff or 1000
    penaltyBelowCutoff = penaltyBelowCutoff or 100000
    wZ = wZ or 1

    obj:queueGameEngineLua([[
        local target = core_groundMarkers.getTargetPos()
        local obj = getObjectByID("]] .. obj:getID() .. [[")
        obj:queueLuaCommand("driver.returnTargetPosition(" .. serialize(target) .. ")")
    ]])
end

local function driveFastToTarget(drivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wZ)
    drivability = drivability or 0.1
    dirMult = dirMult or 1
    penaltyAboveCutoff = penaltyAboveCutoff or 1
    penaltyBelowCutoff = penaltyBelowCutoff or 1
    wZ = wZ or 1

    obj:queueGameEngineLua([[
        local target = core_groundMarkers.getTargetPos()
        local obj = getObjectByID("]] .. obj:getID() .. [[")
        obj:queueLuaCommand("driver.returnTargetPosition(" .. serialize(target) .. ", true)")
    ]])
end



M.driveToTarget = driveToTarget
M.driveFastToTarget = driveFastToTarget
M.returnTargetPosition = returnTargetPosition
M.driveExactPath = driveExactPath
M.cancelExactPathAssist = cancelExactPathAssist
M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX

return M
