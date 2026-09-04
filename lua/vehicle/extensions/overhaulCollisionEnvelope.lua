local M = {}

local function sortedNodeIds(set)
  local ids = {}
  for id in pairs(set) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Return the live collidable body contour used by GE pathing. Door triangles
-- stay out of the preferred contour so an open panel does not fill its doorway.
local function requestCollisionEnvelope(requestId)
  local allNodes, bodyNodes = {}, {}
  local triangleCount, bodyTriangleCount, doorTriangleCount = 0, 0, 0

  for triangleId, triangle in pairs(v.data.triangles or {}) do
    if triangle.triangleType ~= 2 and not obj:isTriangleBroken(triangleId) then
      local doorTriangle = string.find(
        string.lower(tostring(triangle.partPath or "")), "door", 1, true
      ) ~= nil
      triangleCount = triangleCount + 1
      if doorTriangle then
        doorTriangleCount = doorTriangleCount + 1
      else
        bodyTriangleCount = bodyTriangleCount + 1
      end
      for _, nodeId in ipairs({triangle.id1, triangle.id2, triangle.id3}) do
        if nodeId ~= nil then
          allNodes[nodeId] = true
          if not doorTriangle then bodyNodes[nodeId] = true end
        end
      end
    end
  end

  local allNodeIds = sortedNodeIds(allNodes)
  local bodyNodeIds = sortedNodeIds(bodyNodes)
  local pathNodeIds = #bodyNodeIds >= 3 and bodyNodeIds or allNodeIds
  obj:queueGameEngineLua(string.format(
    "if overhaul_walkEnterVehicle then overhaul_walkEnterVehicle.receiveCollisionEnvelope(%s) end",
    serialize({
      vehicleId = objectId,
      requestId = tonumber(requestId) or 0,
      nodeIds = pathNodeIds,
      triangleCount = triangleCount,
      bodyTriangleCount = bodyTriangleCount,
      doorTriangleCount = doorTriangleCount
    })
  ))
end

M.requestCollisionEnvelope = requestCollisionEnvelope

return M
