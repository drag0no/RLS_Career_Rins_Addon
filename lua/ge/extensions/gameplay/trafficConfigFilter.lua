-- Traffic config eligibility: part/metadata rules evaluated once per model/config.
-- Wraps core_multiSpawn.createGroup so broken rollers / square-wheel configs never
-- enter traffic (or parked) pools.

local M = {}

M.dependencies = { 'core_multiSpawn' }

local logTag = 'trafficConfigFilter'
local RULES_PATH = '/gameplay/traffic/trafficConfigPartRules.json'

local rules = nil
local cache = {} -- [model/config] = { ok = bool, reason = string|nil }
local wrapped = false
local originalCreateGroup = nil

local function loadRules()
  local data = jsonReadFile(RULES_PATH)
  if type(data) ~= 'table' then
    log('W', logTag, 'Missing or invalid rules at ' .. RULES_PATH .. '; using built-in defaults')
    data = {
      rejectConfigTypes = { 'Frame', 'joesJunkshell' },
      rejectIfPowerAtMost = 0,
      rejectIfPowerBelow = 60,
      rejectPartValuePatterns = { 'wheel_square' },
      engineSlotNameMustInclude = 'engine',
      engineSlotNameMustNotInclude = { 'ecu', 'internal', 'mount', 'cover', 'lid', 'bay', 'sound' },
      rejectEmptyMainEngineSlot = true,
      requireFrontAndRearWheels = true,
      wheelSlotNamePattern = '^wheel_[FR]',
    }
  end
  rules = data
  table.clear(cache)
  return rules
end

local function getRules()
  if not rules then
    loadRules()
  end
  return rules
end

local function cacheKey(model, config)
  return tostring(model or '') .. '/' .. tostring(config or '')
end

local function lower(s)
  return string.lower(tostring(s or ''))
end

-- "lid" must be a standalone token so slots like "bolide_engine" are not rejected.
local function slotNameHasBannedFragment(slotName, banned)
  local b = lower(banned)
  if b == 'lid' then
    return string.find(slotName, '%f[%w]lid%f[%W]') ~= nil or string.find(slotName, '%f[%w]lid$') ~= nil
  end
  return string.find(slotName, b, 1, true) ~= nil
end

local function isMainEngineSlot(slotName, r)
  local s = lower(slotName)
  local must = lower(r.engineSlotNameMustInclude or 'engine')
  if not string.find(s, must, 1, true) then
    return false
  end
  for _, banned in ipairs(r.engineSlotNameMustNotInclude or {}) do
    if slotNameHasBannedFragment(s, banned) then
      return false
    end
  end
  return true
end

local function partValueRejected(value, r)
  local v = lower(value)
  if v == '' then
    return false
  end
  for _, pat in ipairs(r.rejectPartValuePatterns or {}) do
    if string.find(v, lower(pat), 1, true) then
      return true, pat
    end
  end
  return false
end

local function readParts(model, config)
  if not model or not config or config == '' then
    return nil
  end
  local path = '/vehicles/' .. model .. '/' .. config .. '.pc'
  local ok, data = pcall(jsonReadFile, path)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  return data.parts or data.slotMap or nil
end

local function getConfigInfo(model, config)
  if not core_vehicles or not core_vehicles.getModel then
    return nil
  end
  local modelData = core_vehicles.getModel(model)
  if not modelData or type(modelData.configs) ~= 'table' then
    return nil
  end
  return modelData.configs[config]
end

--- Returns ok, reason. Cached.
local function isConfigEligible(model, config)
  local key = cacheKey(model, config)
  local hit = cache[key]
  if hit ~= nil then
    return hit.ok, hit.reason
  end

  local r = getRules()
  local info = getConfigInfo(model, config)
  local configType = info and (info['Config Type'] or info.configType) or nil
  local power = info and tonumber(info.Power or info.power) or nil

  if configType then
    local ct = lower(configType)
    for _, bad in ipairs(r.rejectConfigTypes or {}) do
      if ct == lower(bad) then
        cache[key] = { ok = false, reason = 'configType:' .. tostring(configType) }
        return false, cache[key].reason
      end
    end
  end

  if power ~= nil then
    local atMost = tonumber(r.rejectIfPowerAtMost)
    if atMost ~= nil and power <= atMost then
      cache[key] = { ok = false, reason = 'powerAtMost:' .. tostring(power) }
      return false, cache[key].reason
    end
    local below = tonumber(r.rejectIfPowerBelow)
    if below ~= nil and power > 0 and power < below then
      cache[key] = { ok = false, reason = 'powerBelow:' .. tostring(power) }
      return false, cache[key].reason
    end
  end

  local parts = readParts(model, config)
  if type(parts) == 'table' then
    local hasFrontWheel, hasRearWheel = false, false
    local sawMainEngine, mainEngineEmpty = false, false

    for slot, value in pairs(parts) do
      local slotName = tostring(slot)
      local val = value == nil and '' or tostring(value)

      local badVal, pat = partValueRejected(val, r)
      if badVal then
        cache[key] = { ok = false, reason = 'partValue:' .. pat .. ':' .. slotName }
        return false, cache[key].reason
      end

      if isMainEngineSlot(slotName, r) then
        sawMainEngine = true
        if val == '' then
          mainEngineEmpty = true
        end
      end

      if r.requireFrontAndRearWheels ~= false then
        local wheelPat = r.wheelSlotNamePattern or '^wheel_[FR]'
        if string.match(slotName, wheelPat) then
          if val == '' then
            cache[key] = { ok = false, reason = 'emptyWheel:' .. slotName }
            return false, cache[key].reason
          end
          if string.match(slotName, '^wheel_F') then
            hasFrontWheel = true
          elseif string.match(slotName, '^wheel_R') then
            hasRearWheel = true
          end
        end
      end
    end

    if r.rejectEmptyMainEngineSlot ~= false and sawMainEngine and mainEngineEmpty then
      cache[key] = { ok = false, reason = 'emptyEngine' }
      return false, cache[key].reason
    end

    -- No main engine slot at all + zero/missing power → treat as roller/shell.
    if r.rejectEmptyMainEngineSlot ~= false and not sawMainEngine and (power == nil or power <= 0) then
      cache[key] = { ok = false, reason = 'noEngine' }
      return false, cache[key].reason
    end

    if r.requireFrontAndRearWheels ~= false and (hasFrontWheel or hasRearWheel) then
      if not hasFrontWheel or not hasRearWheel then
        cache[key] = { ok = false, reason = 'incompleteWheels' }
        return false, cache[key].reason
      end
    end
  end

  cache[key] = { ok = true, reason = nil }
  return true, nil
end

local function wrapMultiSpawn()
  if wrapped then
    return true
  end
  if not core_multiSpawn or type(core_multiSpawn.createGroup) ~= 'function' then
    return false
  end
  if core_multiSpawn._rlsTrafficConfigFilterWrapped then
    wrapped = true
    return true
  end

  -- createGroup uses a *local* getInstalledVehicleData, so wrapping the export is
  -- not enough. Wrap createGroup, oversample, and keep only eligible configs.
  originalCreateGroup = core_multiSpawn.createGroup
  core_multiSpawn.createGroup = function(amount, params)
    amount = amount or 10
    local want = math.max(1, amount)
    local candidates, seenKeys = {}, {}
    local lastBatch = nil

    for _ = 1, 4 do
      local batch = originalCreateGroup(want * 3, params) or {}
      if #batch > 0 then
        lastBatch = batch
      end
      for _, entry in ipairs(batch) do
        local model = entry and entry.model
        local config = entry and entry.config
        local key = tostring(model) .. '/' .. tostring(config)
        if not seenKeys[key] and isConfigEligible(model, config) then
          seenKeys[key] = true
          candidates[#candidates + 1] = entry
        end
      end
      if #candidates >= want * 2 then
        break
      end
    end

    if #candidates == 0 then
      if lastBatch and #lastBatch > 0 then
        log('W', logTag, 'Traffic filter removed all candidates; falling back to unfiltered batch')
        return lastBatch
      end
      return {}
    end

    -- Prioritize vehicle model uniqueness across both the current group and existing world vehicles
    local chosenCounts = {}
    local getVehs = getAllVehicles or getAllVehiclesByType
    if getVehs then
      for _, veh in ipairs(getVehs()) do
        local m = (veh.getJBeamFilename and veh:getJBeamFilename()) or (veh.getField and veh:getField('JBeam', '0')) or veh.jbeam or veh.JBeam
        if m then
          chosenCounts[m] = (chosenCounts[m] or 0) + 1
        end
      end
    end

    local out = {}
    local usedIndices = {}

    -- Multi-pass selection: maximize distinct models before allowing repeats of the same model
    for pass = 0, 3 do
      if #out >= want then break end
      for i, entry in ipairs(candidates) do
        if not usedIndices[i] then
          local model = entry.model or ''
          local count = chosenCounts[model] or 0
          if count <= pass then
            usedIndices[i] = true
            chosenCounts[model] = count + 1
            out[#out + 1] = entry
            if #out >= want then break end
          end
        end
      end
    end

    -- If still short of want, append any remaining candidates
    if #out < want then
      for i, entry in ipairs(candidates) do
        if not usedIndices[i] then
          usedIndices[i] = true
          out[#out + 1] = entry
          if #out >= want then break end
        end
      end
    end

    if #out < want then
      log('W', logTag, string.format('Traffic group short after filter: want %d, got %d', want, #out))
    end
    return out
  end

  core_multiSpawn._rlsTrafficConfigFilterWrapped = true
  wrapped = true
  log('I', logTag, 'Wrapped core_multiSpawn.createGroup for part-based traffic filter')
  return true
end

local function onExtensionUnloaded()
  if originalCreateGroup and core_multiSpawn and core_multiSpawn._rlsTrafficConfigFilterWrapped then
    core_multiSpawn.createGroup = originalCreateGroup
    core_multiSpawn._rlsTrafficConfigFilterWrapped = nil
  end
  originalCreateGroup = nil
  wrapped = false
end

local function onExtensionLoaded()
  loadRules()
  wrapMultiSpawn()
end

local function onCareerActivated()
  wrapMultiSpawn()
end

local function onModActivated()
  table.clear(cache)
  loadRules()
end

local function onFileChanged(filename)
  if type(filename) == 'string' and filename:find('trafficConfigPartRules', 1, true) then
    loadRules()
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onCareerActivated = onCareerActivated
M.onModActivated = onModActivated
M.onFileChanged = onFileChanged

M.isConfigEligible = isConfigEligible
M.reloadRules = loadRules
M.getRules = getRules
M.wrapMultiSpawn = wrapMultiSpawn

return M
