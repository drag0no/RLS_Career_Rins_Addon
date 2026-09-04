-- Player vehicles: the set of vehicles that count as "the player" for world footprint.
--
-- Coupler attach/detach is the membership key for *task proximity*. Coupled
-- trailers join the player footprint so destination checks fire when any of
-- those bodies enter a spot.
--
-- Marker / cargo UI interaction is broader: a nearby spawned inventory vehicle
-- (owned or loaner) also counts, so uncoupling a job trailer in a stall still
-- opens the drop-off prompt.
--
-- Ownership is separate: job trailers remain loaners (owningOrganization, return,
-- org cut/reputation). This module never changes inventory ownership — only which
-- vehicle ids are treated as the player for interaction / proximity.

local M = {}

local dirty = true
local seatedId = nil
local playerIds = {}

-- Scratch for group near queries (callers must not retain).
local nearScratch = {}

-- Uncoupled job trailers sit in the stall next to the truck; 50 m covers a
-- yard without pulling in vehicles at a distant garage.
local INTERACTION_NEAR_SQ = 50 * 50

local function markDirty()
  dirty = true
end

local function vehInCouplers(vehId, list)
  for _, coupler in ipairs(list or {}) do
    if coupler[1] == vehId or coupler[2] == vehId then
      return true
    end
  end
  return false
end

local function walkTreeInto(ids, leadId, tree)
  local function walk(node)
    if not node then return end
    if node.vehId and node.vehId ~= leadId then
      ids[#ids + 1] = node.vehId
    end
    if node.children then
      for _, child in ipairs(node.children) do
        walk(child)
      end
    end
  end
  if tree and tree.children then
    for _, child in ipairs(tree.children) do
      walk(child)
    end
  end
end

--- Coupler group for any root vehicle (lead + attached). Does not touch player cache.
local function fillCouplerGroup(rootVehId, into, opts)
  into = into or {}
  table.clear(into)
  if not rootVehId then
    return into
  end

  local resolveLead = opts and opts.resolveLead
  local leadId = rootVehId
  if resolveLead and core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer then
    -- B-trains can have more than one trailer between the queried vehicle and
    -- the tow vehicle. Walk the whole parent chain so a rear trailer resolves
    -- to the cab instead of stopping at the lead trailer.
    local visited = {}
    while leadId and not visited[leadId] do
      visited[leadId] = true
      local parentId = core_trailerRespawn.getAttachedNonTrailer(leadId)
      if not parentId or parentId == leadId or visited[parentId] then break end
      leadId = parentId
    end
  end

  into[1] = leadId

  local coreVeh = extensions.core_vehicles
  if not coreVeh or not coreVeh.generateAttachedVehiclesTree then
    if rootVehId ~= leadId then
      into[2] = rootVehId
    end
    return into
  end

  local list = coreVeh.attachedCouplers or {}
  if not vehInCouplers(leadId, list) and not (rootVehId ~= leadId and vehInCouplers(rootVehId, list)) then
    if rootVehId ~= leadId then
      into[2] = rootVehId
    end
    return into
  end

  local tree = coreVeh.generateAttachedVehiclesTree(leadId)
  walkTreeInto(into, leadId, tree)

  if rootVehId ~= leadId then
    local found = false
    for _, id in ipairs(into) do
      if id == rootVehId then
        found = true
        break
      end
    end
    if not found then
      into[#into + 1] = rootVehId
    end
  end

  return into
end

local function rebuildPlayerVehicles()
  table.clear(playerIds)
  local pid = be:getPlayerVehicleID(0)
  if not pid or pid == -1 then
    seatedId = nil
    dirty = false
    return
  end

  seatedId = pid
  -- Seated vehicle + everything coupled to it = player vehicles.
  fillCouplerGroup(pid, playerIds)
  dirty = false
end

local function ensurePlayerVehicles()
  local pid = be:getPlayerVehicleID(0)
  if dirty or pid ~= seatedId then
    rebuildPlayerVehicles()
  end
end

--- Ids that currently count as the player (seated + coupled). Do not mutate.
local function getPlayerVehicleIds()
  ensurePlayerVehicles()
  return playerIds
end

local function fillPlayerVehicleIds(into)
  ensurePlayerVehicles()
  table.clear(into)
  for i = 1, #playerIds do
    into[i] = playerIds[i]
  end
  return into
end

local function idInList(list, vehId)
  for i = 1, #list do
    if list[i] == vehId then return true end
  end
  return false
end

--- Seated + coupler group + nearby spawned inventory vehicles (owned/loaner).
--- Use this for parking markers and cargo scans, not for task state machines.
local function fillInteractionVehicleIds(into)
  fillPlayerVehicleIds(into)

  local originId = seatedId
  if not originId or originId == -1 then
    originId = be:getPlayerVehicleID(0)
  end
  local originObj = originId and originId ~= -1 and getObjectByID(originId) or nil
  local originPos = originObj and originObj:getPosition() or nil
  if not originPos and core_camera then
    originPos = core_camera.getPosition()
  end
  if not originPos then
    return into
  end

  local inv = career_modules_inventory
  local map = inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId()
  if not map then
    return into
  end

  for _, vehId in pairs(map) do
    if vehId and not idInList(into, vehId) then
      local obj = getObjectByID(vehId)
      if obj and obj:getJBeamFilename() ~= "unicycle"
          and (obj:getPosition() - originPos):squaredLength() <= INTERACTION_NEAR_SQ then
        into[#into + 1] = vehId
      end
    end
  end
  return into
end

local function getPlayerVehicleCount()
  ensurePlayerVehicles()
  return #playerIds
end

local function isPlayerVehicle(vehId)
  if not vehId then
    return false
  end
  ensurePlayerVehicles()
  for _, id in ipairs(playerIds) do
    if id == vehId then
      return true
    end
  end
  return false
end

--- True if any vehicle in rootVehId's coupler group is within thresholdSq of pos.
local function anyInGroupNear(rootVehId, pos, thresholdSq, opts)
  if not pos then
    return false
  end
  fillCouplerGroup(rootVehId, nearScratch, opts)
  for _, id in ipairs(nearScratch) do
    local obj = scenetree.findObjectById(id)
    if obj and (obj:getPosition() - pos):squaredLength() <= thresholdSq then
      return true
    end
  end
  return false
end

-- Coupler is the membership key.
M.onCouplerAttached = markDirty
M.onCouplerDetached = markDirty
M.onVehicleSwitched = markDirty
M.onVehicleDestroyed = markDirty
M.onExtensionLoaded = markDirty

M.getPlayerVehicleIds = getPlayerVehicleIds
M.fillPlayerVehicleIds = fillPlayerVehicleIds
M.fillInteractionVehicleIds = fillInteractionVehicleIds
M.getPlayerVehicleCount = getPlayerVehicleCount
M.isPlayerVehicle = isPlayerVehicle
M.fillCouplerGroup = fillCouplerGroup
M.anyInGroupNear = anyInGroupNear
M.invalidate = markDirty

return M
