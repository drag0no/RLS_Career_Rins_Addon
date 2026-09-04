-- Surgical patch of vanilla Graphpath:_getPointToPointPathImpl.
-- lua/common is not on the overrideManager path, so we replace the method on
-- the live class metatable instead of overlaying graphpath.lua.
--
-- 1. Per-call minheap: vanilla shares one module-level `que` between GPS jobs
--    (which yield) and traffic getPath. Interleaving corrupts parent pointers.
-- 2. Cycle-safe unroll: vanilla `while target do path[e]=target` has no yield
--    and no cycle check, so a loop grows until LuaJIT table overflow (~30s freeze).

local M = {}

local graphpath = require('graphpath')

local origImpl
local installed = false

local UNROLL_HOP_CAP = 100000

local function patchedImpl(self, sourcePos, iter, targetPos, cutOffDrivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wZ, yieldFn)
  if sourcePos == nil or targetPos == nil or sourcePos == targetPos then return {} end

  local sourceNode, sourceCost, sourceXnorm = iter()
  if sourceNode == nil then return {} end

  local minCost = table.new(0, 32)
  minCost[sourceNode] = sourceCost
  local xnorms = table.new(0, 32)
  xnorms[sourceNode] = sourceXnorm
  local minParent = table.new(0, 32)
  minParent[sourceNode] = false

  local node, cost = sourceNode, sourceCost
  sourceNode, sourceCost, sourceXnorm = nil, nil, nil

  local graph = self.graph
  local positions = self.positions

  wZ = wZ or 1
  cutOffDrivability = cutOffDrivability or 0
  penaltyAboveCutoff = penaltyAboveCutoff or 1
  penaltyBelowCutoff = penaltyBelowCutoff or 10000

  local dirCoeff = {[true] = dirMult or 1, [false] = 1}
  local drivCoeff = {[true] = penaltyAboveCutoff, [false] = penaltyBelowCutoff}

  local road = table.new(0, 32)
  local targetMinCost = square(square(sourcePos.x-targetPos.x) + square(sourcePos.y-targetPos.y) + square(wZ * (sourcePos.z-targetPos.z)))
  local targetMinCostLink = nil
  local nodePos, tmpVec, nodeToTargetVec = vec3(), vec3(), vec3()

  local tmpNode = table.new(0, 2)
  local tmpEdge1Data = table.new(0, 4)
  local tmpEdge2Data = table.new(0, 4)

  local que = graphpath.newMinheap()
  repeat
    profilerPushEvent("Graphpath:getPointToPointPathImpl")
    if road[node] == nil then
      road[node] = minParent[node]
      if node == targetPos then break end

      local nodeLinks
      if graph[node] then
        nodeLinks = graph[node]
        nodePos:set(positions[node])
      else
        local n1id, n2id = node[1], node[2]
        local edgeData = graph[n1id][n2id]
        local dist, driv, inNode, oneWay = edgeData.len, edgeData.drivability, edgeData.inNode, edgeData.oneWay
        local xnorm = xnorms[node]

        table.clear(tmpNode)

        tmpEdge1Data.len = dist * xnorm
        tmpEdge1Data.drivability = driv
        tmpEdge1Data.inNode = (inNode == n2id and node) or inNode
        tmpEdge1Data.oneWay = oneWay
        tmpNode[n1id] = tmpEdge1Data

        tmpEdge2Data.len = dist * (1 - xnorm)
        tmpEdge2Data.drivability = driv
        tmpEdge2Data.inNode = (inNode == n1id and node) or inNode
        tmpEdge2Data.oneWay = oneWay
        tmpNode[n2id] = tmpEdge2Data

        nodeLinks = tmpNode
        nodePos:setLerp(positions[n1id], positions[n2id], xnorm)
      end

      nodeToTargetVec:setSub2(targetPos, nodePos)
      local pathCost = cost + square(square(nodeToTargetVec.x) + square(nodeToTargetVec.y) + square(wZ * nodeToTargetVec.z))
      if pathCost < targetMinCost then
        que:insert(pathCost, targetPos)
        targetMinCost = pathCost
        minParent[targetPos] = node
        targetMinCostLink = nil
      end

      local parent = road[node]
      for child, edgeData in pairs(nodeLinks) do
        local edgeCost
        if road[child] == nil then
          edgeCost = edgeData.len * dirCoeff[edgeData.oneWay and edgeData.inNode == child] * drivCoeff[edgeData.drivability > cutOffDrivability]
          local pathToChildCost = cost + edgeCost
          if pathToChildCost < (minCost[child] or math.huge) then
            que:insert(pathToChildCost, child)
            minCost[child] = pathToChildCost
            minParent[child] = node
          end
        end

        if cost < targetMinCost and child ~= parent then
          tmpVec:setSub2(positions[child], nodePos)
          local xnorm = tmpVec:dot(nodeToTargetVec) / (tmpVec:squaredLength() + 1e-30)
          if xnorm > 0 and xnorm < 1 then
            tmpVec:setScaled(-xnorm)
            tmpVec:setAdd(nodeToTargetVec)
            pathCost = cost +
                      (edgeCost or edgeData.len * dirCoeff[edgeData.oneWay and edgeData.inNode == child] * drivCoeff[edgeData.drivability > cutOffDrivability]) * xnorm +
                      square(square(tmpVec.x) + square(tmpVec.y) + square(wZ * tmpVec.z))
            if pathCost < targetMinCost then
              que:insert(pathCost, targetPos)
              targetMinCost = pathCost
              minParent[targetPos] = node
              targetMinCostLink = child
            end
          end
        end
      end
    end

    if not sourceNode then
      sourceNode, sourceCost, sourceXnorm = iter()
    end

    if (que:peekKey() or math.huge) <= (sourceCost or math.huge) then
      cost, node = que:pop()
    else
      minCost[sourceNode] = sourceCost
      xnorms[sourceNode] = sourceXnorm
      minParent[sourceNode] = false
      node, cost = sourceNode, sourceCost
      sourceNode, sourceCost, sourceXnorm = nil, nil, nil
    end

    if yieldFn then yieldFn() end
    profilerPopEvent("Graphpath:getPointToPointPathImpl")
  until not node

  if not node then return {} end

  local path = {targetMinCostLink}
  local e = #path
  local target = road[node]
  local seen = table.new(0, 32)
  local hops = 0
  while target do
    if seen[target] or hops >= UNROLL_HOP_CAP then
      return {}
    end
    seen[target] = true
    hops = hops + 1
    e = e + 1
    path[e] = target
    target = road[target]
  end

  if e == 0 then return {} end

  if graph[path[e]] == nil then
    local tmp1 = path[e][1]
    local tmp2 = path[e][2]
    path[e] = nil
    e = e - 1
    if path[e] == tmp1 and path[e-1] ~= tmp2 then
      e = e + 1
      path[e] = tmp2
    elseif path[e] == tmp2 and path[e-1] ~= tmp1 then
      e = e + 1
      path[e] = tmp1
    end
  end

  for i = 1, e * 0.5 do
    path[i], path[e] = path[e], path[i]
    e = e - 1
  end

  return path
end

local function install()
  if type(graphpath.newGraphpath) ~= 'function' then
    return false
  end
  local dummy = graphpath.newGraphpath(0)
  local C = getmetatable(dummy)
  if type(C) ~= 'table' or type(C._getPointToPointPathImpl) ~= 'function' then
    return false
  end
  if C._getPointToPointPathImpl == patchedImpl then
    installed = true
    return true
  end
  origImpl = C._getPointToPointPathImpl
  C._getPointToPointPathImpl = patchedImpl
  installed = true
  return true
end

local function restore()
  if not origImpl then
    return
  end
  local dummy = graphpath.newGraphpath(0)
  local C = getmetatable(dummy)
  if type(C) == 'table' and C._getPointToPointPathImpl == patchedImpl then
    C._getPointToPointPathImpl = origImpl
  end
  installed = false
end

local function onExtensionLoaded()
  install()
end

local function onClientStartMission()
  install()
end

local function onExtensionUnloaded()
  restore()
end

M.install = install
M.onExtensionLoaded = onExtensionLoaded
M.onClientStartMission = onClientStartMission
M.onExtensionUnloaded = onExtensionUnloaded

return M
