-- Finite / soft damage assessment for roadside repair spots.
-- Complements stock "fully broken part" repair (integrityValue == 0):
-- soft integrity, cosmetics, integrityState faults, and tire flat/wear.
-- Kept separate from inventoryVehNeedsRepair so garage gates stay stock-strict.
-- Lines are fully enumerated (no truncate); UI uses "Show more" + selection.

local M = {}

M.dependencies = {'career_career'}

-- Soft integrity only when clearly below perfect (avoids float noise).
local SOFT_INTEGRITY_THRESHOLD = 0.97
-- Worn tires: only call out when under half life (was 0.9 — nearly-new false positives).
local WORN_TIRE_REMAINING = 0.5

local SOFT_INTEGRITY_MIN = 15
local SOFT_INTEGRITY_MAX = 80
-- Bent/deformed mesh with integrity still > 0 (not mileage paint fade).
local COSMETIC_DEFORM_FEE = 35
local INTEGRITY_STATE_FEE = 45
local FLAT_TIRE_FEE = 60
local WORN_TIRE_MIN = 10
local WORN_TIRE_MAX = 40
local FINITE_MINIMUM = 40

local function getVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId or not career_modules_inventory or not career_modules_inventory.getVehicles then
    return nil, nil
  end
  local vehicles = career_modules_inventory.getVehicles() or {}
  return vehicles[inventoryId], inventoryId
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function roundMoney(n)
  return math.floor((tonumber(n) or 0) + 0.5)
end

local function shortPartPath(partPath)
  if type(partPath) ~= "string" or partPath == "" then
    return "Unknown part"
  end
  local leaf = partPath:match("([^/\\]+)$")
  return leaf or partPath
end

local function makeLine(kind, label, detail, cost, meta)
  meta = meta or {}
  local selectable = meta.selectable
  if selectable == nil then
    selectable = kind ~= "info"
  end
  return {
    id = meta.id,
    kind = kind,
    label = label,
    detail = detail,
    cost = roundMoney(cost),
    selectable = selectable == true,
    partPath = meta.partPath,
    partSlotPath = meta.partSlotPath,
    wheelName = meta.wheelName,
  }
end

-- BeamNG always dumps powertrain integrityState (damageFrictionCoef=1, isBroken=false, etc.)
-- even on healthy parts. Only flag real damage, not the presence of the table.
local HEALTHY_DAMAGE_COEF = 1
local COEF_EPS = 0.05

local function integrityStateNeedsAttention(integrityState)
  if type(integrityState) ~= "table" then
    return false, nil
  end

  local issues = {}

  local function add(msg)
    table.insert(issues, msg)
  end

  if integrityState.isBroken == true then
    add("isBroken")
  end
  if integrityState.clutchPermanentlyDamaged == true then
    add("clutchPermanentlyDamaged")
  end

  for key, value in pairs(integrityState) do
    if key == "energyStorage" then
      -- Fuel / battery fill level — not repair damage.
    elseif type(value) == "number" then
      local lower = string.lower(tostring(key))
      if lower:find("leak", 1, true) and value > 0 then
        add(string.format("%s=%.3f", key, value))
      elseif lower:find("chance", 1, true) and value > 0.01 then
        add(string.format("%s=%.3f", key, value))
      elseif lower:find("damage", 1, true) or lower:find("wear", 1, true) then
        -- Most damage*Coef rise above 1 as they worsen; gear-ratio change coef falls below 1.
        if lower:find("gearratio", 1, true) or lower:find("locktorque", 1, true) or lower:find("freeplay", 1, true) then
          if value < HEALTHY_DAMAGE_COEF - COEF_EPS then
            add(string.format("%s=%.3f", key, value))
          end
        elseif value > HEALTHY_DAMAGE_COEF + COEF_EPS then
          add(string.format("%s=%.3f", key, value))
        end
      end
    elseif type(value) == "boolean" and value == true and key ~= "isBroken" and key ~= "clutchPermanentlyDamaged" then
      -- Ignore unknown false flags; only true bools beyond the known ones.
      if string.lower(tostring(key)):find("broken", 1, true)
        or string.lower(tostring(key)):find("damage", 1, true)
        or string.lower(tostring(key)):find("fail", 1, true) then
        add(tostring(key))
      end
    end
  end

  if #issues == 0 then
    return false, nil
  end
  table.sort(issues)
  return true, table.concat(issues, ", ")
end

local function clearIntegrityStateKeepFuel(info)
  if type(info) ~= "table" then
    return
  end
  if info.integrityState and type(info.integrityState.energyStorage) == "table" then
    for _, tankData in pairs(info.integrityState.energyStorage) do
      if type(tankData) == "table" then
        for attributeName, _ in pairs(tankData) do
          if attributeName ~= "storedEnergy" then
            tankData[attributeName] = nil
          end
        end
      end
    end
    info.integrityState = {energyStorage = info.integrityState.energyStorage}
  else
    info.integrityState = nil
  end
end

local function isHardcoreMode()
  return career_career and career_career.isHardcoreMode and career_career.isHardcoreMode()
end

local function partMarketMultiplier()
  if career_modules_valueCalculator and career_modules_valueCalculator.getPartMarketMultiplier then
    return career_modules_valueCalculator.getPartMarketMultiplier() or 1
  end
  return 1
end

local function brokenReplacePrice(part)
  local price = (part and part.value or 700) * partMarketMultiplier()
  if isHardcoreMode() then
    return math.floor(price * 1.25 * 100) / 100
  end
  return math.floor(price * 0.9 * 100) / 100
end

local function bumpBrokenPartRepairCount(inventoryId, partSlotPath, partPath)
  if not career_modules_partInventory then
    return
  end
  local inventoryPart = nil
  if partSlotPath and career_modules_partInventory.getPart then
    inventoryPart = career_modules_partInventory.getPart(inventoryId, partSlotPath)
  end
  if not inventoryPart and partPath and career_modules_partInventory.getPartPathToPartIdMap then
    local map = career_modules_partInventory.getPartPathToPartIdMap()
    local partId = map and map[inventoryId] and map[inventoryId][partPath]
    local inv = career_modules_partInventory.getInventory and career_modules_partInventory.getInventory()
    inventoryPart = partId and inv and inv[partId] or nil
  end
  if not inventoryPart then
    return
  end
  inventoryPart.repairCount = (inventoryPart.repairCount or 0) + 1
  local vehicle = career_modules_inventory and career_modules_inventory.getVehicles
    and career_modules_inventory.getVehicles()[inventoryId]
  if vehicle and inventoryPart.containingSlot then
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[inventoryPart.containingSlot] = true
  end
end

local function healBrokenPart(vehicle, inventoryId, partPath, partSlotPath)
  local info = vehicle.partConditions and vehicle.partConditions[partPath]
  if type(info) ~= "table" or tonumber(info.integrityValue) ~= 0 then
    return false
  end
  bumpBrokenPartRepairCount(inventoryId, partSlotPath, partPath)
  if info.visualState and info.visualState.paint and info.visualState.paint.originalPaints then
    info.visualState = {
      paint = {
        originalPaints = info.visualState.paint.originalPaints,
        odometer = 0,
      },
    }
  else
    info.visualState = nil
  end
  info.visualValue = 1
  clearIntegrityStateKeepFuel(info)
  info.integrityValue = 1
  return true
end

local function healAllBrokenParts(vehicle, inventoryId)
  local n = 0
  if type(vehicle.partConditions) ~= "table" then
    return n
  end
  for partPath, info in pairs(vehicle.partConditions) do
    if type(info) == "table" and tonumber(info.integrityValue) == 0 then
      if healBrokenPart(vehicle, inventoryId, partPath, nil) then
        n = n + 1
      end
    end
  end
  return n
end

local function collectBrokenReplaceLines(vehicle, inventoryId, lines)
  local brokenParts = 0
  local brokenPartsCost = 0
  if type(vehicle.partConditions) ~= "table" or type(vehicle.config) ~= "table" or not vehicle.config.partsTree then
    return brokenParts, brokenPartsCost
  end

  local function traverse(node)
    if not node or not node.partPath then return end
    local partCondition = vehicle.partConditions[node.partPath]
    if partCondition and partCondition.integrityValue and partCondition.integrityValue == 0 then
      brokenParts = brokenParts + 1
      local part = nil
      if career_modules_partInventory and career_modules_partInventory.getPart and node.path then
        part = career_modules_partInventory.getPart(inventoryId, node.path)
      end
      local price = brokenReplacePrice(part)
      brokenPartsCost = brokenPartsCost + price
      local label = (part and (part.niceName or part.name)) or shortPartPath(node.partPath)
      table.insert(lines, makeLine(
        "broken",
        "Replace: " .. tostring(label),
        "Fully broken (integrity 0)",
        price,
        {
          id = "broken:" .. tostring(node.partPath),
          partPath = node.partPath,
          partSlotPath = node.path,
        }
      ))
    end
    if node.children then
      for _, child in pairs(node.children) do
        traverse(child)
      end
    end
  end

  traverse(vehicle.config.partsTree)
  return brokenParts, brokenPartsCost
end

local function collectFinitePartLines(partConditions, lines)
  local softCost, cosmeticCost, stateCost = 0, 0, 0
  local softN, cosmeticN, stateN = 0, 0, 0
  if type(partConditions) ~= "table" then
    return softN, cosmeticN, stateN, softCost, cosmeticCost, stateCost
  end

  local paths = {}
  for partPath, _ in pairs(partConditions) do
    table.insert(paths, partPath)
  end
  table.sort(paths)

  for _, partPath in ipairs(paths) do
    local info = partConditions[partPath]
    if type(info) == "table" then
      local label = shortPartPath(partPath)
      local integrity = tonumber(info.integrityValue)

      if integrity ~= nil and integrity > 0 and integrity < SOFT_INTEGRITY_THRESHOLD then
        softN = softN + 1
        local severity = 1 - integrity
        local cost = clamp(SOFT_INTEGRITY_MIN + severity * (SOFT_INTEGRITY_MAX - SOFT_INTEGRITY_MIN), SOFT_INTEGRITY_MIN, SOFT_INTEGRITY_MAX)
        softCost = softCost + cost
        table.insert(lines, makeLine(
          "soft",
          "Repair: " .. label,
          string.format("Soft damage (integrity %.0f%%)", integrity * 100),
          cost,
          {id = "soft:" .. partPath, partPath = partPath}
        ))
      end

      -- Do NOT use visualValue: career trucks get ~0.8 from odometer paint fade and look fine.
      -- Only charge cosmetics for mesh deformation (visualState.jbeam) while integrity > 0.
      -- Fully broken parts already cover integrity 0 + jbeam via the replace line.
      local vs = info.visualState
      if type(vs) == "table" and vs.jbeam ~= nil and integrity ~= nil and integrity > 0 then
        cosmeticN = cosmeticN + 1
        cosmeticCost = cosmeticCost + COSMETIC_DEFORM_FEE
        table.insert(lines, makeLine(
          "cosmetic",
          "Straighten: " .. label,
          "Bent / deformed mesh",
          COSMETIC_DEFORM_FEE,
          {id = "cosmetic:" .. partPath, partPath = partPath}
        ))
      end

      -- Only when integrity is still "fine" — soft/broken lines already cover damaged parts.
      -- integrityState alone is usually a healthy powertrain dump (coefs at 1).
      local needsState, stateKeys = integrityStateNeedsAttention(info.integrityState)
      if needsState and (integrity == nil or integrity >= SOFT_INTEGRITY_THRESHOLD) then
        stateN = stateN + 1
        stateCost = stateCost + INTEGRITY_STATE_FEE
        table.insert(lines, makeLine(
          "state",
          "Fault: " .. label,
          "State: " .. (stateKeys or "unknown"),
          INTEGRITY_STATE_FEE,
          {id = "state:" .. partPath, partPath = partPath}
        ))
      end
    end
  end

  return softN, cosmeticN, stateN, softCost, cosmeticCost, stateCost
end

local function collectTireLines(vehicle, lines)
  local flats, worn, tireCost = 0, 0, 0
  local layout = vehicle and vehicle.rlsTireLayout
  local wheels = layout and layout.wheels
  if type(wheels) ~= "table" then
    return flats, worn, tireCost
  end

  for _, wheel in ipairs(wheels) do
    if type(wheel) == "table" then
      local name = tostring(wheel.name or "tire")
      if wheel.flat == true then
        flats = flats + 1
        tireCost = tireCost + FLAT_TIRE_FEE
        table.insert(lines, makeLine(
          "tire",
          "Flat tire: " .. name,
          "Needs inflate / replace",
          FLAT_TIRE_FEE,
          {id = "tire:" .. name, wheelName = name}
        ))
      else
        local remaining = tonumber(wheel.remaining)
        if remaining ~= nil and remaining < WORN_TIRE_REMAINING then
          worn = worn + 1
          local severity = 1 - clamp(remaining, 0, 1)
          local cost = clamp(WORN_TIRE_MIN + severity * (WORN_TIRE_MAX - WORN_TIRE_MIN), WORN_TIRE_MIN, WORN_TIRE_MAX)
          tireCost = tireCost + cost
          table.insert(lines, makeLine(
            "tire",
            "Worn tire: " .. name,
            string.format("%.0f%% remaining", remaining * 100),
            cost,
            {id = "tire:" .. name, wheelName = name}
          ))
        end
      end
    end
  end

  return flats, worn, tireCost
end

local function ensureTireSystem()
  if career_modules_tireSystem then
    return career_modules_tireSystem
  end
  pcall(function()
    if extensions and extensions.load then
      extensions.load("career_modules_tireSystem")
    end
  end)
  return career_modules_tireSystem
end

local function toIdSet(selectedIds)
  local set = {}
  if type(selectedIds) ~= "table" then
    return set
  end
  for _, id in ipairs(selectedIds) do
    if type(id) == "string" and id ~= "" then
      set[id] = true
    end
  end
  -- Also accept map-style { [id] = true } from some Lua bridges.
  for key, value in pairs(selectedIds) do
    if type(key) == "string" and value then
      set[key] = true
    end
  end
  return set
end

--- Assess finite + broken damage for roadside repair quoting.
-- @return table assessment (includes full `lines` for UI selection)
function M.assess(inventoryId)
  local vehicle, id = getVehicle(inventoryId)
  if not vehicle then
    return {
      ok = false,
      hasDamage = false,
      hasBrokenParts = false,
      hasFiniteDamage = false,
      hasTireDamage = false,
      brokenParts = 0,
      brokenPartsCost = 0,
      finiteCost = 0,
      totalPreLabor = 0,
      lines = {},
      reason = "Vehicle not found.",
    }
  end

  local lines = {}
  local brokenParts, brokenPartsCost = collectBrokenReplaceLines(vehicle, id, lines)

  -- Fallback count if tree walk found nothing but dict still has integrity 0 entries.
  if brokenParts == 0 and career_modules_valueCalculator and career_modules_valueCalculator.getNumberOfBrokenParts then
    local dictBroken = career_modules_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions) or 0
    if dictBroken > 0 and career_modules_valueCalculator.getRepairDetails then
      local ok, details = pcall(career_modules_valueCalculator.getRepairDetails, vehicle)
      if ok and type(details) == "table" then
        brokenParts = tonumber(details.partsCountToBeReplaced) or dictBroken
        brokenPartsCost = tonumber(details.price) or 0
        table.insert(lines, makeLine(
          "broken",
          string.format("Replace %d fully broken part(s)", brokenParts),
          "Priced via repair details (no part names available)",
          brokenPartsCost,
          {id = "broken:all"}
        ))
      end
    end
  end

  local softN, cosmeticN, stateN, softCost, cosmeticCost, stateCost = collectFinitePartLines(vehicle.partConditions, lines)
  local flats, worn, tireCost = collectTireLines(vehicle, lines)
  local finiteSum = softCost + cosmeticCost + stateCost + tireCost
  local hasFinite = (softN + cosmeticN + stateN + flats + worn) > 0
  if hasFinite and finiteSum < FINITE_MINIMUM then
    local bump = FINITE_MINIMUM - finiteSum
    finiteSum = FINITE_MINIMUM
    table.insert(lines, makeLine(
      "info",
      "Minimum service charge",
      "Applied when any soft/cosmetic/tire work is selected",
      bump,
      {id = "info:minimum", selectable = false}
    ))
  end

  local hasBroken = brokenParts > 0
  local hasDamage = hasBroken or hasFinite

  return {
    ok = true,
    hasDamage = hasDamage,
    hasBrokenParts = hasBroken,
    hasFiniteDamage = hasFinite,
    hasTireDamage = (flats + worn) > 0,
    brokenParts = brokenParts,
    softIntegrityParts = softN,
    cosmeticParts = cosmeticN,
    stateFaultParts = stateN,
    flatTires = flats,
    wornTires = worn,
    brokenPartsCost = roundMoney(brokenPartsCost),
    finiteCost = roundMoney(finiteSum),
    softCost = roundMoney(softCost),
    cosmeticCost = roundMoney(cosmeticCost),
    stateCost = roundMoney(stateCost),
    tireCost = roundMoney(tireCost),
    totalPreLabor = roundMoney(brokenPartsCost + finiteSum),
    finiteMinimum = FINITE_MINIMUM,
    lines = lines,
    reason = hasDamage and nil or "No damage to repair.",
  }
end

--- Quote a subset of damage lines (pre-labor). Re-assesses so prices stay current.
function M.quoteSelection(inventoryId, selectedIds)
  local assessment = M.assess(inventoryId)
  if not assessment.ok or not assessment.hasDamage then
    return {
      ok = false,
      message = assessment.reason or "No damage to repair.",
      selectedLines = {},
      brokenPartsCost = 0,
      finiteCost = 0,
      totalPreLabor = 0,
      hasBrokenParts = false,
      hasFiniteDamage = false,
      hasTireDamage = false,
      selectedCount = 0,
    }
  end

  local idSet = toIdSet(selectedIds)
  -- Empty selection = nothing to do (UI should block). Nil/missing = treat as all selectable.
  local selectAll = selectedIds == nil
  if selectAll then
    for _, line in ipairs(assessment.lines or {}) do
      if line.selectable and line.id then
        idSet[line.id] = true
      end
    end
  end

  local selectedLines = {}
  local brokenPartsCost, finiteRaw = 0, 0
  local hasBroken, hasFinite, hasTire = false, false, false

  for _, line in ipairs(assessment.lines or {}) do
    if line.selectable and line.id and idSet[line.id] then
      table.insert(selectedLines, line)
      if line.kind == "broken" then
        brokenPartsCost = brokenPartsCost + (tonumber(line.cost) or 0)
        hasBroken = true
      elseif line.kind == "tire" then
        finiteRaw = finiteRaw + (tonumber(line.cost) or 0)
        hasFinite = true
        hasTire = true
      elseif line.kind ~= "info" then
        finiteRaw = finiteRaw + (tonumber(line.cost) or 0)
        hasFinite = true
      end
    end
  end

  if #selectedLines == 0 then
    return {
      ok = false,
      message = "Select at least one item to repair.",
      selectedLines = {},
      brokenPartsCost = 0,
      finiteCost = 0,
      totalPreLabor = 0,
      hasBrokenParts = false,
      hasFiniteDamage = false,
      hasTireDamage = false,
      selectedCount = 0,
    }
  end

  local finiteCost = finiteRaw
  local minimumApplied = 0
  if hasFinite and finiteCost < FINITE_MINIMUM then
    minimumApplied = FINITE_MINIMUM - finiteCost
    finiteCost = FINITE_MINIMUM
  end

  return {
    ok = true,
    selectedLines = selectedLines,
    selectedCount = #selectedLines,
    brokenPartsCost = roundMoney(brokenPartsCost),
    finiteCost = roundMoney(finiteCost),
    finiteRaw = roundMoney(finiteRaw),
    minimumApplied = roundMoney(minimumApplied),
    totalPreLabor = roundMoney(brokenPartsCost + finiteCost),
    hasBrokenParts = hasBroken,
    hasFiniteDamage = hasFinite,
    hasTireDamage = hasTire,
  }
end

local function applySelectedLine(vehicle, inventoryId, line)
  if not line or not line.kind then
    return false
  end

  if line.kind == "broken" then
    if line.id == "broken:all" or not line.partPath then
      return healAllBrokenParts(vehicle, inventoryId) > 0
    end
    return healBrokenPart(vehicle, inventoryId, line.partPath, line.partSlotPath)
  end

  if line.kind == "soft" and line.partPath then
    local info = vehicle.partConditions and vehicle.partConditions[line.partPath]
    if type(info) ~= "table" then
      return false
    end
    local integrity = tonumber(info.integrityValue)
    if integrity == nil or integrity <= 0 or integrity >= SOFT_INTEGRITY_THRESHOLD then
      return false
    end
    info.integrityValue = 1
    clearIntegrityStateKeepFuel(info)
    return true
  end

  if line.kind == "cosmetic" and line.partPath then
    local info = vehicle.partConditions and vehicle.partConditions[line.partPath]
    if type(info) ~= "table" then
      return false
    end
    local vs = info.visualState
    if type(vs) ~= "table" or vs.jbeam == nil then
      return false
    end
    -- Clear deformation; keep paint / odometer fade (mileage visualValue).
    vs.jbeam = nil
    if vs.paint then
      info.visualState = {paint = vs.paint}
    else
      info.visualState = nil
    end
    return true
  end

  if line.kind == "state" and line.partPath then
    local info = vehicle.partConditions and vehicle.partConditions[line.partPath]
    if type(info) ~= "table" then
      return false
    end
    local needs = integrityStateNeedsAttention(info.integrityState)
    if not needs then
      return false
    end
    clearIntegrityStateKeepFuel(info)
    return true
  end

  -- Tires are applied in bulk after the loop.
  if line.kind == "tire" then
    return line.wheelName ~= nil
  end

  return false
end

--- Apply only the selected damage lines, then refresh tires/vehicle as needed.
function M.applySelection(inventoryId, selectedIds)
  inventoryId = tonumber(inventoryId)
  local vehicle = getVehicle(inventoryId)
  if not vehicle then
    return {ok = false, message = "Vehicle not found."}
  end

  local quote = M.quoteSelection(inventoryId, selectedIds)
  if not quote.ok then
    return quote
  end

  local applied = 0
  local failedLines = {}
  local wheelNames = {}
  for _, line in ipairs(quote.selectedLines) do
    if line.kind == "tire" and line.wheelName then
      wheelNames[line.wheelName] = true
    elseif applySelectedLine(vehicle, inventoryId, line) then
      applied = applied + 1
    else
      table.insert(failedLines, line)
    end
  end

  local tireFixed = false
  if next(wheelNames) then
    local tires = ensureTireSystem()
    if tires and tires.forceFreshWheels then
      tireFixed = tires.forceFreshWheels(inventoryId, wheelNames) and true or false
    elseif tires and tires.forceFreshForVehicle then
      tireFixed = tires.forceFreshForVehicle(inventoryId) and true or false
    end
    if tireFixed then
      applied = applied + 1
    else
      for _, line in ipairs(quote.selectedLines) do
        if line.kind == "tire" then
          table.insert(failedLines, line)
        end
      end
    end
  end

  if applied <= 0 then
    return {ok = false, message = "Could not apply selected repairs."}
  end

  if career_modules_inventory and career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end

  -- Clear combat/crash damage state only when no fully broken parts remain.
  local post = M.assess(inventoryId)
  if not post.hasBrokenParts and career_modules_damageManager and career_modules_damageManager.clearDamageState then
    career_modules_damageManager.clearDamageState(inventoryId)
  end

  return {
    ok = true,
    applied = applied,
    tireFixed = tireFixed,
    quote = quote,
    failedLines = failedLines,
    remainingDamage = post.hasDamage == true,
  }
end

--- Inflate / refresh tires after a roadside finite repair (works with maintenance mode off).
function M.applyTireFix(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  local assessment = M.assess(inventoryId)
  if not assessment.hasTireDamage then
    return false
  end
  local tires = ensureTireSystem()
  if tires and tires.forceFreshForVehicle then
    return tires.forceFreshForVehicle(inventoryId) and true or false
  end
  return false
end

function M.hasRepairableDamage(inventoryId)
  local a = M.assess(inventoryId)
  return a.hasDamage == true
end

return M
