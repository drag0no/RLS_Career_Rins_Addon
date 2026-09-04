local M = {}
M.dependencies = { "career_career", "career_saveSystem", "career_modules_business_businessManager" }

local jbeamIO = require("jbeam/io")

local inventory = {}
local businessPartInventoryPath = "business/partInventory.json"
local businessPartInventoryQuarantinePath = "business/partInventoryQuarantine.json"
local inventoryLoaded = false
local saveInventory
local activeBusinessId = nil
local pricePartIoCtxCache = {}

local function normalizeBusinessId(businessId)
  if businessId == nil or businessId == "" then
    return nil
  end
  return tostring(businessId)
end

local function partOwnerIsPurchasedBusiness(part)
  if not part then
    return false
  end
  local bid = normalizeBusinessId(part.businessId)
  if not bid then
    return false
  end
  local mgr = career_modules_business_businessManager
  if not mgr or not mgr.isPurchasedBusiness or not mgr.getAllPurchasedBusinesses then
    return false
  end
  local all = mgr.getAllPurchasedBusinesses()
  if type(all) ~= "table" then
    return false
  end
  for businessType, _ in pairs(all) do
    if type(businessType) == "string" and mgr.isPurchasedBusiness(businessType, bid) then
      return true
    end
  end
  return false
end

local function appendQuarantineEntries(entries)
  if not entries or #entries == 0 then
    return
  end
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then
    return
  end
  local path = savePath .. "/career/" .. businessPartInventoryQuarantinePath
  local existing = jsonReadFile(path)
  local list = {}
  if type(existing) == "table" then
    for _, row in ipairs(existing) do
      table.insert(list, row)
    end
  end
  for _, row in ipairs(entries) do
    table.insert(list, row)
  end
  jsonWriteFile(path, list, true)
end

local function validateInventoryOwnershipAfterLoad()
  local mgr = career_modules_business_businessManager
  if not mgr or not mgr.isBusinessOwnershipReady or not mgr.isBusinessOwnershipReady() then
    return
  end
  local toRemove = {}
  local batch = {}
  for partId, part in pairs(inventory) do
    if part and not partOwnerIsPurchasedBusiness(part) then
      table.insert(toRemove, partId)
      local reason = "invalid_owner"
      if not normalizeBusinessId(part.businessId) then
        reason = "missing_owner"
      end
      table.insert(batch, {
        quarantinedAt = os.time(),
        reason = reason,
        part = deepcopy(part),
      })
    end
  end
  if #toRemove == 0 then
    return
  end
  appendQuarantineEntries(batch)
  for _, partId in ipairs(toRemove) do
    inventory[partId] = nil
  end
  saveInventory()
  log(
    "I",
    "businessPartInventory",
    string.format(
      "Quarantined %d part inventory row(s) with missing or invalid business ownership (see career/business/partInventoryQuarantine.json).",
      #toRemove
    )
  )
end

local function onPurchasedBusinessesOwnershipReady()
  if not inventoryLoaded then
    return
  end
  validateInventoryOwnershipAfterLoad()
end

local function partBelongsToBusiness(part, businessId)
  if not part then
    return false
  end
  local want = normalizeBusinessId(businessId)
  if not want then
    return false
  end
  local pid = part.businessId
  if pid == nil or tostring(pid) == "" then
    return false
  end
  return tostring(pid) == want
end

local function getInventory()
  return inventory
end

local function getPartsByModel(model, businessId)
  local parts = {}
  local bid = normalizeBusinessId(businessId)
  if not bid then
    return parts
  end
  for _, part in pairs(inventory) do
    if part and part.vehicleModel == model and partBelongsToBusiness(part, bid) then
      table.insert(parts, part)
    end
  end
  return parts
end

local function generatePartId()
  local id = 1
  while inventory[id] do
    id = id + 1
  end
  return id
end

local function addPart(part, ownerBusinessId)
  if not part then
    return nil
  end
  local ob = normalizeBusinessId(ownerBusinessId or part.businessId or activeBusinessId)
  if not ob then
    log("W", "businessPartInventory", "addPart: missing businessId — part not added.")
    return nil
  end

  local newPart = {
    name = part.name,
    vehicleModel = part.vehicleModel,
    year = part.year,
    partCondition = deepcopy(part.partCondition or {integrityValue = 1, odometer = 0, visualValue = 1}),
    slot = part.slot or part.slotType, -- Try to store slot if available
    containingSlot = part.containingSlot,
    partPath = part.partPath,
    rlsTireState = type(part.rlsTireState) == "table" and deepcopy(part.rlsTireState) or nil,
    businessId = ob,
  }

  local id = generatePartId()
  newPart.partId = id
  inventory[id] = newPart
  saveInventory()
  return id
end

local function addParts(partsList, ownerBusinessId)
  if not partsList then
    return
  end
  for _, part in ipairs(partsList) do
    addPart(part, ownerBusinessId)
  end
  saveInventory()
end

local function removePart(partId, ownerBusinessId)
  local p = inventory[partId]
  if not p then
    return false
  end
  local ob = normalizeBusinessId(ownerBusinessId)
  if ob and not partBelongsToBusiness(p, ob) then
    return false
  end
  inventory[partId] = nil
  saveInventory()
  return true
end

local function updatePartCondition(partId, condition)
  if inventory[partId] then
    inventory[partId].partCondition = deepcopy(condition)
    return true
  end
  return false
end

local function loadInventory()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then
    return
  end

  local filePath = savePath .. "/career/" .. businessPartInventoryPath
  local data = jsonReadFile(filePath)
  inventory = {}
  pricePartIoCtxCache = {}

  if data then
    if type(data) == "table" then
      for idx, part in pairs(data) do
        if part and type(part) == "table" then
          local partId = part.partId or tonumber(idx) or idx
          inventory[partId] = part
          if not part.partId then
            part.partId = partId
          end
        end
      end
    end
  else
    inventory = {}
  end
  validateInventoryOwnershipAfterLoad()
  inventoryLoaded = true
end

saveInventory = function()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then
    return
  end

  local partsArray = {}
  for _, part in pairs(inventory) do
    if part then
      table.insert(partsArray, part)
    end
  end
  jsonWriteFile(savePath .. "/career/" .. businessPartInventoryPath, partsArray, true)
  inventoryLoaded = true
end

local function loadJBeamDataForParts(parts)
  local jBeamPartInfos = {}
  local vehicleModels = {}

  for _, part in pairs(parts) do
    if part.vehicleModel then
      vehicleModels[part.vehicleModel] = true
    end
  end

  for vehicleModel, _ in pairs(vehicleModels) do
    local vehicleDir = string.format("/vehicles/%s/", vehicleModel)
    if FS:directoryExists(vehicleDir) then
      local vehicleFolders = {vehicleDir, "/vehicles/common/"}
      local ioCtx = jbeamIO.startLoading(vehicleFolders)
      jBeamPartInfos[vehicleModel] = jbeamIO.getAvailableParts(ioCtx)
    end
  end

  return jBeamPartInfos
end

local function getUIData(businessId)
  activeBusinessId = businessId
  local bid = normalizeBusinessId(businessId)

  if not inventoryLoaded then
    loadInventory()
  end

  local uiData = {}

  local partsByModel = {}

  local ioContexts = {}

  local partCount = 0
  for _, part in pairs(inventory) do
    if part and bid and partBelongsToBusiness(part, bid) then
      partCount = partCount + 1
      if not partsByModel[part.vehicleModel] then
        partsByModel[part.vehicleModel] = {}
      end

      local expandedPart = deepcopy(part)

      if not ioContexts[part.vehicleModel] then
        local vehicleDir = string.format("/vehicles/%s/", part.vehicleModel)
        if FS:directoryExists(vehicleDir) then
          local vehicleFolders = {vehicleDir, "/vehicles/common/"}
          ioContexts[part.vehicleModel] = jbeamIO.startLoading(vehicleFolders)
        end
      end

      local ioCtx = ioContexts[part.vehicleModel]
      local jbeamData = nil
      if ioCtx then
        jbeamData = jbeamIO.getPart(ioCtx, part.name)
      end

      if jbeamData then
        expandedPart.value = jbeamData.information and jbeamData.information.value or 100
        expandedPart.niceName = jbeamData.information and jbeamData.information.name or part.name
        expandedPart.description = expandedPart.niceName -- Fallback/Compatible field

        if not expandedPart.slot and jbeamData.slotType then
          expandedPart.slot = jbeamData.slotType
        end
      else
        expandedPart.description = part.name .. " (Unknown)"
        expandedPart.niceName = part.name
        expandedPart.value = 0
      end

      local modelData = core_vehicles.getModel(part.vehicleModel)
      if modelData and modelData.model then
        local brand = modelData.model.Brand or ""
        local name = modelData.model.Name
        expandedPart.vehicleNiceName = (brand .. " " .. name):match("^%s*(.-)%s*$")
      else
        expandedPart.vehicleNiceName = part.vehicleModel
      end

      if career_modules_valueCalculator then
        local success, baseValue = pcall(function()
          return career_modules_valueCalculator.getPartValue(expandedPart, true)
        end)
        if success and baseValue then
          expandedPart.finalValue = baseValue
        else
          expandedPart.finalValue = (expandedPart.value or 0) * 0.55
        end
      end

      table.insert(partsByModel[part.vehicleModel], expandedPart)
    end
  end

  uiData.partsByModel = partsByModel
  uiData.partCount = partCount
  return uiData
end

local function onExtensionLoaded()
  if not career_career.isActive() then
    return false
  end
  loadInventory()
end

local function onCareerActive(currentSavePath)
  loadInventory()
end

local function onSaveCurrentProfile(currentSavePath)
  saveInventory()
end

local function pricePartForSale(part)
  if not part then
    return 0
  end
  local price = 0
  if career_modules_valueCalculator then
    local expandedPart = deepcopy(part)
    local jbeamData = nil
    local ioCtx = pricePartIoCtxCache[part.vehicleModel]
    if ioCtx == nil then
      local vehicleDir = string.format("/vehicles/%s/", part.vehicleModel)
      if FS:directoryExists(vehicleDir) then
        ioCtx = jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
      end
      pricePartIoCtxCache[part.vehicleModel] = ioCtx or false
    end
    if ioCtx then
      jbeamData = jbeamIO.getPart(ioCtx, part.name)
    end

    if jbeamData and jbeamData.information then
      expandedPart.value = jbeamData.information.value or 100
      expandedPart.niceName = jbeamData.information.name or part.name
    else
      expandedPart.value = 100
      expandedPart.niceName = part.name
    end

    price = career_modules_valueCalculator.getPartValue(expandedPart, true) or 0
  else
    price = 55
  end
  return price
end

local function sellPart(partId, businessId)
  if not partId then
    return false, 0
  end
  local part = inventory[partId]
  if not part then
    return false, 0
  end
  if not partBelongsToBusiness(part, businessId) then
    return false, 0
  end

  local price = pricePartForSale(part)
  inventory[partId] = nil
  saveInventory()
  return true, price
end

local function sellAllParts(businessId)
  if not normalizeBusinessId(businessId) then
    return false, 0
  end

  local totalPrice = 0
  local partsToRemove = {}

  for partId, part in pairs(inventory) do
    if part and partBelongsToBusiness(part, businessId) then
      local price = pricePartForSale(part)
      totalPrice = totalPrice + price
      table.insert(partsToRemove, partId)
    end
  end

  for _, partId in ipairs(partsToRemove) do
    inventory[partId] = nil
  end

  saveInventory()
  return true, totalPrice
end

local function getLiquidationValue(businessId)
  if not normalizeBusinessId(businessId) then
    return 0
  end
  if not inventoryLoaded then
    loadInventory()
  end
  local totalPrice = 0
  for _, part in pairs(inventory) do
    if part and partBelongsToBusiness(part, businessId) then
      totalPrice = totalPrice + pricePartForSale(part)
    end
  end
  return totalPrice
end

local function clearBusinessParts(businessId)
  if not normalizeBusinessId(businessId) then
    return 0
  end
  if not inventoryLoaded then
    loadInventory()
  end
  local removed = 0
  for partId, part in pairs(inventory) do
    if part and partBelongsToBusiness(part, businessId) then
      inventory[partId] = nil
      removed = removed + 1
    end
  end
  saveInventory()
  return removed
end

local function sellPartsByVehicle(vehicleModel, businessId)
  if not vehicleModel or not career_modules_valueCalculator then
    return false, 0
  end
  if not normalizeBusinessId(businessId) then
    return false, 0
  end

  local totalPrice = 0
  local partsToRemove = {}

  for partId, part in pairs(inventory) do
    if part and part.vehicleModel == vehicleModel and partBelongsToBusiness(part, businessId) then
      local price = pricePartForSale(part)
      totalPrice = totalPrice + price
      table.insert(partsToRemove, partId)
    end
  end

  for _, partId in ipairs(partsToRemove) do
    inventory[partId] = nil
  end

  saveInventory()
  return true, totalPrice
end

M.addPart = addPart
M.addParts = addParts
M.removePart = removePart
M.getInventory = getInventory
M.getPartsByModel = getPartsByModel
M.updatePartCondition = updatePartCondition
M.getUIData = getUIData
M.loadInventory = loadInventory
M.saveInventory = saveInventory
M.sellPart = sellPart
M.sellAllParts = sellAllParts
M.sellPartsByVehicle = sellPartsByVehicle
M.getLiquidationValue = getLiquidationValue
M.clearBusinessParts = clearBusinessParts

M.onExtensionLoaded = onExtensionLoaded
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onPurchasedBusinessesOwnershipReady = onPurchasedBusinessesOwnershipReady

return M
