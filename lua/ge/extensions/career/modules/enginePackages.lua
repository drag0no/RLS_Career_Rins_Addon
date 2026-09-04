local M = {}

M.dependencies = {
  "career_career",
  "career_saveSystem",
  "career_modules_inventory",
  "career_modules_partInventory",
  "career_modules_computer",
  "career_modules_garageManager",
  "career_modules_permissions"
}

local jbeamIO = require("jbeam/io")
local jbeamSlotSystem = require("jbeam/slotSystem")

local logTag = "enginePackages"
local saveVersion = 1
local saveRelativePath = "/career/rls_career/enginePackages.json"
local thumbnailRelativeDir = "/career/rls_career/enginePackages/"
local thumbnailCaptureVersion = 5

local packages = {}
local nextPackageId = 1
local menuOpen = false
local currentInventoryId
local originComputerId
local transactionBusy = false
local loaded = false
local getPackageStatus

local function countTableEntries(value)
  local count = 0
  for _ in pairs(value or {}) do
    count = count + 1
  end
  return count
end

local function trim(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$") or ""
end

local function getCurrentSavePath()
  local _, savePath = career_saveSystem.getCurrentProfile()
  return savePath
end

local function normalizeSavePath(savePath)
  savePath = savePath or getCurrentSavePath()
  if not savePath then return nil end
  if savePath:sub(1, 1) ~= "/" then
    savePath = "/" .. savePath
  end
  return savePath
end

local function ensureSaveDirectory(filePath)
  local dirPath = filePath and filePath:match("^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath, true)
  end
end

local function getPackageThumbnailDiskPath(packageId, savePath)
  savePath = savePath or getCurrentSavePath()
  if not savePath or not packageId then return nil end
  return savePath .. thumbnailRelativeDir .. tostring(packageId) .. ".jpg"
end

local function getPackageThumbnailUiPath(packageId, savePath)
  local filePath = getPackageThumbnailDiskPath(packageId, savePath)
  return filePath and normalizeSavePath(filePath) or nil
end

local function packageThumbnailExists(packageId)
  local diskPath = getPackageThumbnailDiskPath(packageId)
  local uiPath = getPackageThumbnailUiPath(packageId)
  return (diskPath and FS:fileExists(diskPath)) or (uiPath and FS:fileExists(uiPath)) or false
end

local function getPackageThumbnailPath(packageId, savePath)
  if not packageThumbnailExists(packageId) then return nil end
  return getPackageThumbnailUiPath(packageId, savePath)
end

local function deletePackageThumbnail(packageId)
  local diskPath = getPackageThumbnailDiskPath(packageId)
  local uiPath = getPackageThumbnailUiPath(packageId)
  if diskPath and FS:fileExists(diskPath) then FS:removeFile(diskPath) end
  if uiPath and uiPath ~= diskPath and FS:fileExists(uiPath) then FS:removeFile(uiPath) end
end

local function saveData(currentSavePath)
  currentSavePath = currentSavePath or getCurrentSavePath()
  if not currentSavePath then return false end

  local filePath = currentSavePath .. saveRelativePath
  ensureSaveDirectory(filePath)
  jsonWriteFile(filePath, {
    version = saveVersion,
    nextPackageId = nextPackageId,
    packages = packages
  }, true)
  return true
end

local function getPartInventory()
  return career_modules_partInventory and career_modules_partInventory.getInventory and
    career_modules_partInventory.getInventory() or {}
end

local function restoreTable(target, snapshot)
  table.clear(target)
  for key, value in pairs(snapshot or {}) do
    target[key] = deepcopy(value)
  end
end

local function getPackageById(packageId)
  packageId = tostring(packageId or "")
  for _, package in ipairs(packages) do
    if tostring(package.id) == packageId then
      return package
    end
  end
end

local function getPartIdsFromPackageTree(node, result)
  result = result or {}
  if not node then return result end
  if node.partId then
    table.insert(result, tonumber(node.partId) or node.partId)
  end
  for _, child in pairs(node.children or {}) do
    getPartIdsFromPackageTree(child, result)
  end
  return result
end

local function clearPackageFlags(package)
  local inventory = getPartInventory()
  for _, partId in ipairs(getPartIdsFromPackageTree(package and package.tree)) do
    local part = inventory[partId]
    if part and tostring(part.enginePackageId or "") == tostring(package.id) then
      part.enginePackageId = nil
      part.mainPart = part.containingSlot == "/"
    end
  end
end

local function removePackage(packageId, clearFlags)
  packageId = tostring(packageId or "")
  for index, package in ipairs(packages) do
    if tostring(package.id) == packageId then
      if clearFlags then clearPackageFlags(package) end
      table.remove(packages, index)
      return package
    end
  end
end

local function repairPackageFlags()
  local inventory = getPartInventory()
  local validPackageIds = {}
  for _, package in ipairs(packages) do
    validPackageIds[tostring(package.id)] = true
  end

  for _, part in pairs(inventory) do
    local packageId = part.enginePackageId and tostring(part.enginePackageId)
    if packageId and not validPackageIds[packageId] then
      part.enginePackageId = nil
      part.mainPart = part.containingSlot == "/"
    end
  end

  for _, package in ipairs(packages) do
    for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
      local part = inventory[partId]
      if part then
        part.enginePackageId = tostring(package.id)
        part.mainPart = true
      end
    end
    if getPackageStatus then
      local status, installedInventoryId = getPackageStatus(package)
      if status == "installed" then package.installedInventoryId = installedInventoryId end
      if status == "stored" then package.installedInventoryId = nil end
    end
  end
end

local function loadData()
  packages = {}
  nextPackageId = 1

  local savePath = getCurrentSavePath()
  local filePath = savePath and (savePath .. saveRelativePath)
  local data = filePath and FS:fileExists(filePath) and jsonReadFile(filePath) or nil
  if type(data) == "table" and type(data.packages) == "table" then
    packages = data.packages
    nextPackageId = math.max(tonumber(data.nextPackageId) or 1, 1)
  end

  for _, package in ipairs(packages) do
    package.id = tostring(package.id)
    local numericId = tonumber(package.id)
    if numericId then
      nextPackageId = math.max(nextPackageId, numericId + 1)
    end
  end

  repairPackageFlags()
  loaded = true
end

local function getSpawnedVehicleObject(inventoryId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  return vehId and getObjectByID(vehId), vehId
end

local function getRuntimeVehicleData(inventoryId)
  local vehObj, vehId = getSpawnedVehicleObject(inventoryId)
  if not vehObj or not vehId then return nil, nil, nil end
  return extensions.core_vehicle_manager.getVehicleData(vehId), vehObj, vehId
end

local function pathDepth(path)
  local depth = 0
  for _ in string.gmatch(path or "", "[^/]+") do depth = depth + 1 end
  return depth
end

local function jbeamHasDeviceType(partData, deviceType)
  if type(partData) ~= "table" then return false end
  local target = string.lower(deviceType)
  local function walk(value)
    if type(value) == "string" then
      -- Substring match so "classic_combustionEngine" matches "combustionEngine".
      return string.find(string.lower(value), target, 1, true) ~= nil
    end
    if type(value) ~= "table" then return false end
    for _, child in pairs(value) do
      if walk(child) then return true end
    end
    return false
  end
  return walk(partData.powertrain)
end

local function partIsCombustionEngine(ioCtx, partName)
  if not partName or partName == "" or not ioCtx then return false end
  return jbeamHasDeviceType(jbeamIO.getPart(ioCtx, partName), "combustionEngine")
end

local function partIsElectricMotor(ioCtx, partName)
  if not partName or partName == "" or not ioCtx then return false end
  return jbeamHasDeviceType(jbeamIO.getPart(ioCtx, partName), "electricMotor")
end

local function collectPowertrainFlags(tree, ioCtx)
  local hasCombustion, hasElectric = false, false
  local function visit(node)
    if not node then return end
    local name = node.chosenPartName
    if name and name ~= "" then
      if partIsCombustionEngine(ioCtx, name) then hasCombustion = true end
      if partIsElectricMotor(ioCtx, name) then hasElectric = true end
    end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(tree)
  return hasCombustion, hasElectric
end

local function vehicleIsElectric(inventoryId)
  local vehicle = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  local fuel = vehicle and vehicle.certificationData and vehicle.certificationData.fuelType
  if type(fuel) == "string" and string.find(string.lower(fuel), "electric", 1, true) then
    return true
  end
  if type(fuel) == "table" then
    local hasLiquid = fuel["fuelTank:gasoline"] or fuel["fuelTank:diesel"]
    if fuel["fuelTank:electric"] and not hasLiquid then return true end
  end

  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not runtimeData or not runtimeData.config then return false end
  local hasCombustion, hasElectric = collectPowertrainFlags(runtimeData.config.partsTree, runtimeData.ioCtx)
  if hasCombustion then return false end
  return hasElectric
end

local function findEngineCandidates(tree, includeEmpty, ioCtx)
  local candidates = {}

  local function visit(node, parentPartName)
    if not node then return end
    for slotName, child in pairs(node.children or {}) do
      local lowerSlot = string.lower(slotName)
      local hasInstalledPart = child and child.chosenPartName and child.chosenPartName ~= ""
      local looksLikeEngineSlot = child and string.find(lowerSlot, "engine", 1, true)
        and not string.find(lowerSlot, "electric", 1, true)
      local isCombustion = hasInstalledPart and partIsCombustionEngine(ioCtx, child.chosenPartName)
      local include = looksLikeEngineSlot and (isCombustion or (includeEmpty and not hasInstalledPart))
      if include then
        table.insert(candidates, {
          node = child,
          slotName = slotName,
          path = child.path or ((node.path or "/") .. slotName .. "/"),
          parentPartName = node.chosenPartName
        })
      end
      visit(child, child.chosenPartName or parentPartName)
    end
  end

  visit(tree, tree and tree.chosenPartName)
  table.sort(candidates, function(a, b)
    local depthA, depthB = pathDepth(a.path), pathDepth(b.path)
    if depthA ~= depthB then return depthA < depthB end
    return tostring(a.path) < tostring(b.path)
  end)
  return candidates
end

local function getPrimaryEngine(tree, ioCtx)
  return findEngineCandidates(tree, false, ioCtx)[1]
end

local function getDescriptionText(description, fallback)
  if type(description) == "string" then return description end
  if type(description) == "table" then
    if type(description.description) == "string" then return description.description end
    if type(description.description) == "table" then
      return getDescriptionText(description.description, fallback)
    end
    if type(description.name) == "string" then return description.name end
  end
  return fallback
end

local function getPartNiceName(ioCtx, partName)
  local availableParts = ioCtx and jbeamIO.getAvailableParts(ioCtx) or {}
  local description = availableParts and availableParts[partName]
  return getDescriptionText(description, partName or "Engine")
end

local function collectVariableNamesFromValue(value, result, seen)
  if type(value) ~= "table" or seen[value] then return end
  seen[value] = true

  if type(value.name) == "string" and value.name:sub(1, 1) == "$" then
    result[value.name] = true
  end
  if type(value[1]) == "string" and value[1]:sub(1, 1) == "$" then
    result[value[1]] = true
  end

  for key, child in pairs(value) do
    if type(key) == "string" and key:sub(1, 1) == "$" then
      result[key] = true
    end
    if type(child) == "table" then
      collectVariableNamesFromValue(child, result, seen)
    end
  end
end

local function collectEngineVariableNames(packageTree, ioCtx)
  local result = {}
  local function visit(node)
    if not node then return end
    local partData = node.name and jbeamIO.getPart(ioCtx, node.name)
    if partData and partData.variables then
      collectVariableNamesFromValue(partData.variables, result, {})
    end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(packageTree)
  return result
end

local function captureTuning(packageTree, runtimeData, vehicleConfig)
  local tuning = {}
  local definitions = runtimeData and runtimeData.vdata and runtimeData.vdata.variables or {}
  local names = collectEngineVariableNames(packageTree, runtimeData and runtimeData.ioCtx)
  for variableName in pairs(names) do
    local definition = definitions and definitions[variableName]
    local value = definition and definition.val
    if value == nil and vehicleConfig and vehicleConfig.vars then value = vehicleConfig.vars[variableName] end
    if value == nil and definition then value = definition.default end
    if value ~= nil then tuning[variableName] = value end
  end
  return tuning
end

local function makePackageTree(node, inventoryId)
  local inventory = getPartInventory()

  local function findPartId(path)
    for partId, part in pairs(inventory) do
      if tonumber(part.location) == tonumber(inventoryId) and part.containingSlot == path then
        return partId
      end
    end
  end

  local function copyNode(source, relativeSlot)
    local partId = findPartId(source.path)
    if not partId then return nil, "Could not locate owned part for " .. tostring(source.chosenPartName) end
    local result = {
      name = source.chosenPartName,
      partId = partId,
      relativeSlot = relativeSlot,
      children = {}
    }
    for slotName, child in pairs(source.children or {}) do
      if child.chosenPartName and child.chosenPartName ~= "" then
        local copied, err = copyNode(child, slotName)
        if not copied then return nil, err end
        result.children[slotName] = copied
      end
    end
    return result
  end

  return copyNode(node)
end

local function collectTreePartEntries(node, basePath, result)
  result = result or {}
  if not node then return result end
  table.insert(result, {
    partId = tonumber(node.partId) or node.partId,
    name = node.name,
    containingSlot = basePath,
    partPath = basePath .. tostring(node.name or "")
  })
  for slotName, child in pairs(node.children or {}) do
    collectTreePartEntries(child, basePath .. slotName .. "/", result)
  end
  return result
end

local function makeConfigTree(node, basePath, slotId)
  local result = {
    id = slotId or node.relativeSlot,
    chosenPartName = node.name,
    path = basePath,
    partPath = basePath .. tostring(node.name or ""),
    decisionMethod = "user",
    children = {}
  }
  for slotName, child in pairs(node.children or {}) do
    result.children[slotName] = makeConfigTree(child, basePath .. slotName .. "/", slotName)
  end
  return result
end

local function findPackageForInventory(inventoryId)
  for _, package in ipairs(packages) do
    if tonumber(package.installedInventoryId) == tonumber(inventoryId) then
      return package
    end
  end
end

local function uniquePackageName(baseName, exceptPackageId)
  baseName = trim(baseName)
  if baseName == "" then baseName = "Engine Package" end
  local used = {}
  for _, package in ipairs(packages) do
    if tostring(package.id) ~= tostring(exceptPackageId or "") then
      used[string.lower(package.name or "")] = true
    end
  end
  if not used[string.lower(baseName)] then return baseName end
  local suffix = 2
  while used[string.lower(baseName .. " " .. suffix)] do suffix = suffix + 1 end
  return baseName .. " " .. suffix
end

local function captureCurrentEngineActual(inventoryId, requestedName, existingPackage)
  local vehicles = career_modules_inventory.getVehicles()
  local vehicle = vehicles and vehicles[inventoryId]
  local runtimeData, vehObj = getRuntimeVehicleData(inventoryId)
  if not vehicle or not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not vehObj then
    return nil, "The selected vehicle is not spawned."
  end

  local engine = getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
  if not engine then return nil, "No installed engine slot was found." end

  local packageTree, treeError = makePackageTree(engine.node, inventoryId)
  if not packageTree then return nil, treeError end

  local package = existingPackage
  if not package then
    package = {id = tostring(nextPackageId)}
    nextPackageId = nextPackageId + 1
    table.insert(packages, package)
  else
    local newIds = {}
    for _, id in ipairs(getPartIdsFromPackageTree(packageTree)) do newIds[id] = true end
    local inventory = getPartInventory()
    for _, oldId in ipairs(getPartIdsFromPackageTree(package.tree)) do
      if not newIds[oldId] then
        local oldPart = inventory[oldId]
        if oldPart and tostring(oldPart.enginePackageId or "") == tostring(package.id) then
          oldPart.enginePackageId = nil
          oldPart.mainPart = oldPart.containingSlot == "/"
        end
      end
    end
  end

  local engineNiceName = getPartNiceName(runtimeData.ioCtx, packageTree.name)
  local desiredName = trim(requestedName)
  if desiredName == "" then desiredName = package.name or (engineNiceName .. " Package") end
  package.name = uniquePackageName(desiredName, package.id)
  package.rootSlotName = engine.slotName
  package.rootPath = engine.path
  package.rootEngineName = packageTree.name
  package.rootEngineNiceName = engineNiceName
  package.tree = packageTree
  package.tuning = captureTuning(packageTree, runtimeData, vehicle.config)
  package.createdModel = package.createdModel or vehicle.model
  package.lastInstalledModel = vehicle.model
  package.installedInventoryId = inventoryId
  package.updatedAt = os.time()
  package.createdAt = package.createdAt or package.updatedAt

  local inventory = getPartInventory()
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local part = inventory[partId]
    if part then
      part.enginePackageId = tostring(package.id)
      part.mainPart = true
    end
  end

  return package
end

getPackageStatus = function(package)
  local inventory = getPartInventory()
  local location
  local missing = 0
  local mixed = false
  local ids = getPartIdsFromPackageTree(package.tree)
  for _, partId in ipairs(ids) do
    local part = inventory[partId]
    if not part then
      missing = missing + 1
    elseif location == nil then
      location = tonumber(part.location) or part.location
    elseif tostring(location) ~= tostring(part.location) then
      mixed = true
    end
  end

  if missing > 0 then return "incomplete", nil, missing end
  if mixed or location == nil then return "incomplete", nil, missing end
  if tonumber(location) == 0 then return "stored", nil, 0 end
  return "installed", tonumber(location) or location, 0
end

local function getSlotInfo(availableParts, parentPartName, slotName)
  local parentInfo = availableParts and availableParts[parentPartName]
  return parentInfo and parentInfo.slotInfoUi and parentInfo.slotInfoUi[slotName]
end

local function validatePackageTreeFits(node, parentPartName, slotName, ioCtx, availableParts)
  if not node or not node.name then return false, "Package tree is incomplete." end
  local partData = jbeamIO.getPart(ioCtx, node.name)
  if not partData then return false, "Missing part: " .. tostring(node.name) end
  local slotInfo = getSlotInfo(availableParts, parentPartName, slotName)
  if not slotInfo or not jbeamSlotSystem.partFitsSlot(partData, slotInfo) then
    return false, tostring(node.name) .. " does not fit " .. tostring(slotName)
  end
  for childSlot, child in pairs(node.children or {}) do
    local ok, err = validatePackageTreeFits(child, node.name, childSlot, ioCtx, availableParts)
    if not ok then return false, err end
  end
  return true
end

local function findCompatibleTarget(package, inventoryId)
  if vehicleIsElectric(inventoryId) then
    return nil, "Electric vehicles cannot swap engines."
  end
  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
    return nil, "The selected vehicle is not spawned."
  end

  local inventory = getPartInventory()
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    if not inventory[partId] then return nil, "The package is missing one or more parts." end
  end

  local availableParts = jbeamIO.getAvailableParts(runtimeData.ioCtx)
  local matches = {}
  for _, candidate in ipairs(findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
    local ok = validatePackageTreeFits(package.tree, candidate.parentPartName, candidate.slotName, runtimeData.ioCtx, availableParts)
    if ok then table.insert(matches, candidate) end
  end
  if #matches == 0 then return nil, "This engine package does not fit the selected vehicle." end
  for _, candidate in ipairs(matches) do
    if candidate.slotName == package.rootSlotName then return candidate end
  end
  if #matches > 1 then return nil, "More than one compatible engine slot was found." end
  return matches[1]
end

local function getConditionSummary(package)
  local inventory = getPartInventory()
  local integrityTotal, integrityCount, maxOdometer = 0, 0, 0
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local condition = inventory[partId] and inventory[partId].partCondition
    if type(condition) == "table" then
      local integrity = tonumber(condition.integrityValue)
      if integrity then
        integrityTotal = integrityTotal + integrity
        integrityCount = integrityCount + 1
      end
      maxOdometer = math.max(maxOdometer, tonumber(condition.odometer) or 0)
    end
  end
  return integrityCount > 0 and (integrityTotal / integrityCount) or 1, maxOdometer
end

local function getVehicleName(inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return nil end
  local name = vehicle.niceName or vehicle.model
  if core_locales and core_locales.translateWithOrWithoutContext then
    return core_locales.translateWithOrWithoutContext(name)
  end
  return type(name) == "table" and (name.txt or vehicle.model) or name
end

local function buildUIData()
  local result = {
    busy = transactionBusy,
    currentInventoryId = currentInventoryId,
    currentPackageId = nil,
    hasInstalledEngine = false,
    packages = {}
  }
  if currentInventoryId then
    local runtimeData = getRuntimeVehicleData(currentInventoryId)
    result.hasInstalledEngine = runtimeData and runtimeData.config and not vehicleIsElectric(currentInventoryId) and getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx) ~= nil or false
  end
  local currentPackage = currentInventoryId and findPackageForInventory(currentInventoryId)
  result.currentPackageId = currentPackage and tostring(currentPackage.id) or nil

  for _, package in ipairs(packages) do
    local status, installedInventoryId, missingCount = getPackageStatus(package)
    package.installedInventoryId = installedInventoryId
    local compatible, compatibilityReason = false, nil
    if currentInventoryId and status ~= "incomplete" then
      local target, err = findCompatibleTarget(package, currentInventoryId)
      compatible = target ~= nil
      compatibilityReason = err
    end
    local integrity, odometer = getConditionSummary(package)
    local thumbnailPath = getPackageThumbnailPath(package.id)
    table.insert(result.packages, {
      id = tostring(package.id),
      name = package.name,
      rootEngineName = package.rootEngineName,
      rootEngineNiceName = package.rootEngineNiceName or package.rootEngineName,
      partCount = #getPartIdsFromPackageTree(package.tree),
      tuningCount = countTableEntries(package.tuning),
      integrity = integrity,
      odometer = odometer,
      status = status,
      missingCount = missingCount,
      installedInventoryId = installedInventoryId,
      installedVehicleName = installedInventoryId and getVehicleName(installedInventoryId) or nil,
      createdModel = package.createdModel,
      lastInstalledModel = package.lastInstalledModel,
      compatible = compatible,
      compatibilityReason = compatibilityReason,
      canInstall = not transactionBusy and status == "stored" and compatible,
      canStore = not transactionBusy and status == "installed" and tonumber(installedInventoryId) == tonumber(currentInventoryId),
      canDismantle = not transactionBusy,
      thumbnail = thumbnailPath,
      dirtyDate = package.thumbnailAt or package.updatedAt or 0
    })
  end

  table.sort(result.packages, function(a, b)
    if a.status ~= b.status then return a.status == "installed" end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return result
end

local function sendUIData()
  if not menuOpen then return end
  guihooks.trigger("enginePackagesData", buildUIData())
end

local function sendResult(success, message)
  guihooks.trigger("enginePackagesActionResult", {success = success == true, message = message or ""})
  sendUIData()
end

local function collectLivePartPaths(node, result)
  result = result or {}
  if not node then return result end
  local partPath = node.partPath
  if (not partPath or partPath == "") and node.path and (node.chosenPartName or node.name) then
    partPath = node.path .. tostring(node.chosenPartName or node.name)
  end
  if partPath and partPath ~= "" then
    result[partPath] = true
  end
  for _, child in pairs(node.children or {}) do
    collectLivePartPaths(child, result)
  end
  return result
end

local function collectLivePartNames(node, result)
  result = result or {}
  if not node then return result end
  local name = node.chosenPartName or node.name
  if name and name ~= "" then result[name] = true end
  for _, child in pairs(node.children or {}) do
    collectLivePartNames(child, result)
  end
  return result
end

local function expandPartPathsFromVdata(vdata, partNames, partPaths)
  partPaths = partPaths or {}
  if not vdata or not partNames then return partPaths end

  local function consider(path)
    if type(path) ~= "string" or path == "" or partPaths[path] then return end
    local name = path:match("([^/]+)$")
    if name and partNames[name] then
      partPaths[path] = true
    end
  end

  if vdata.flexbodies then
    for _, flexbody in pairs(vdata.flexbodies) do
      if type(flexbody) == "table" then consider(flexbody.partPath) end
    end
  end
  if vdata.props then
    for _, prop in pairs(vdata.props) do
      if type(prop) == "table" then consider(prop.partPath) end
    end
  end
  if vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" then consider(node.partPath) end
    end
  end
  return partPaths
end

local function restoreVehiclePartVisibility(vehObj, vehId)
  -- highlightParts leaves engine-only state in partmgmt. Always reset that
  -- and force mesh alpha, using the live object for this vehId when possible.
  if vehId then
    local live = getObjectByID(vehId)
    if live then vehObj = live end
  end
  if vehId and core_vehicle_partmgmt then
    pcall(core_vehicle_partmgmt.resetVehicleHighlights, false, vehId)
    pcall(core_vehicle_partmgmt.showHighlightedParts, vehId)
  end
  if vehObj then
    pcall(function() vehObj:setMeshAlpha(1, "") end)
  end
end

local function unhideInventoryVehicle(inventoryId)
  local vehObj, vehId = getSpawnedVehicleObject(inventoryId)
  restoreVehiclePartVisibility(vehObj, vehId)
end

-- Parts that extend far from the engine block and should not dominate framing.
local function isPeripheralEnginePart(name)
  if not name then return false end
  local lower = string.lower(name)
  if string.find(lower, "exhaust", 1, true) then return true end
  if string.find(lower, "transmission", 1, true) then return true end
  if string.find(lower, "gearbox", 1, true) then return true end
  if string.find(lower, "transfercase", 1, true) then return true end
  if string.find(lower, "driveshaft", 1, true) then return true end
  if string.find(lower, "radiator", 1, true) then return true end
  if string.find(lower, "intercooler", 1, true) then return true end
  return false
end

local function frameEngineCamera(vehObj, vdata, partPaths, partNames)
  local vehPos = vehObj:getPosition()
  local minP, maxP
  local seen = {}
  local nodeCount = 0

  -- Separate core engine parts from peripheral parts (exhaust, trans, etc.).
  local corePartPaths = {}
  local corePartNames = {}
  local peripheralPartPaths = {}
  for path in pairs(partPaths) do
    local name = path:match("([^/]+)$")
    if isPeripheralEnginePart(name) then
      peripheralPartPaths[path] = true
    else
      corePartPaths[path] = true
    end
  end
  for name in pairs(partNames) do
    if not isPeripheralEnginePart(name) then
      corePartNames[name] = true
    end
  end

  local function considerCid(cid)
    if cid == nil or seen[cid] then return end
    seen[cid] = true
    local nodePos = vehObj:getNodePosition(cid)
    if not nodePos then return end
    local world = nodePos + vehPos
    nodeCount = nodeCount + 1
    if not minP then
      minP = vec3(world.x, world.y, world.z)
      maxP = vec3(world.x, world.y, world.z)
    else
      minP.x = math.min(minP.x, world.x)
      minP.y = math.min(minP.y, world.y)
      minP.z = math.min(minP.z, world.z)
      maxP.x = math.max(maxP.x, world.x)
      maxP.y = math.max(maxP.y, world.y)
      maxP.z = math.max(maxP.z, world.z)
    end
  end

  -- First pass: only core engine parts (block, heads, intake, etc.).
  if vdata and vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" and node.cid ~= nil then
        local pathMatch = node.partPath and corePartPaths[node.partPath]
        local nameMatch = node.partOrigin and corePartNames[node.partOrigin]
        if pathMatch or nameMatch then considerCid(node.cid) end
      end
    end
  end

  -- If no core nodes found, fall back to all engine parts.
  if nodeCount == 0 and vdata and vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" and node.cid ~= nil then
        local match = (node.partPath and partPaths[node.partPath]) or (node.partOrigin and partNames[node.partOrigin])
        if match then considerCid(node.cid) end
      end
    end
  end

  local bb = vehObj:getSpawnWorldOOBB()
  local axis0, axis1, axis2 = bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)
  local lookAt, size
  if minP and maxP then
    lookAt = (minP + maxP) * 0.5
    size = maxP - minP
  else
    local half = bb:getHalfExtents()
    lookAt = bb:getCenter() + axis1 * (half.y * 0.4) + axis2 * (half.z * 0.2)
    size = vec3(0.8, 1.0, 0.6)
  end

  -- Never aim at the pavement; thin hoods/covers sit just above the ground AABB.
  local groundZ = bb:getCenter().z - bb:getHalfExtents().z
  local minLookZ = groundZ + 0.45
  if lookAt.z < minLookZ then
    lookAt = lookAt + axis2 * (minLookZ - lookAt.z)
  end
  lookAt = lookAt + axis2 * math.max(size.z * 0.2, 0.12)

  -- Use the plan-view size so a flat cover still gets a sensible standoff.
  local xyDim = math.max(size.x, size.y, 0.55)
  local maxDim = math.max(xyDim, size.z * 1.3, 0.55)
  local fov = 28
  local distance = (maxDim * 0.95) / math.tan(math.rad(fov) * 0.5)
  distance = math.max(1.05, math.min(distance, 2.8))

  -- 3/4 view, only a little above horizontal so the part fills the frame instead of the lot.
  local camOffset = (axis0 * -0.72 + axis1 * -0.88 + axis2 * 0.22):normalized()
  local camPos = lookAt + camOffset * distance
  local camRot = quatFromDir(lookAt - camPos, axis2)
  log("I", logTag, string.format("Engine frame nodes=%d size=%.2f dist=%.2f fov=%d lookZ=%.2f", nodeCount, maxDim, distance, fov, lookAt.z))
  return camPos, camRot, fov
end

local thumbnailQueue = {}
local thumbnailBusy = false
local capturingPackageId
local pendingAfterIdle = {}

local function captureEngineThumbnailNow(packageId, inventoryId, callback)
  local finished = false
  local isolated = false
  local vehObj, vehId, runtimeData

  local function restore()
    if not isolated then return end
    unhideInventoryVehicle(inventoryId)
    restoreVehiclePartVisibility(vehObj, vehId)
    isolated = false
  end

  local function done(ok, reason)
    if finished then return end
    finished = true
    restore()
    if not ok then
      log("W", logTag, "Engine thumbnail failed for package " .. tostring(packageId) .. ": " .. tostring(reason or "unknown"))
    else
      log("I", logTag, "Engine thumbnail saved for package " .. tostring(packageId))
    end
    if callback then
      local cbOk, cbErr = pcall(callback, ok == true)
      if not cbOk then
        log("E", logTag, "Engine thumbnail callback failed: " .. tostring(cbErr))
      end
    end
  end

  local package = getPackageById(packageId)
  runtimeData, vehObj, vehId = getRuntimeVehicleData(inventoryId)
  if not package then
    done(false, "package not found")
    return
  end
  if not runtimeData or not vehObj then
    done(false, "vehicle is not spawned")
    return
  end

  local engine = runtimeData.config and getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
  if not engine or not engine.node then
    done(false, "no installed engine slot")
    return
  end

  local partPaths = collectLivePartPaths(engine.node)
  local partNames = collectLivePartNames(engine.node)
  expandPartPathsFromVdata(runtimeData.vdata, partNames, partPaths)
  if not next(partPaths) then
    done(false, "engine part paths were empty")
    return
  end
  log("I", logTag, "Engine isolate parts=" .. tostring(countTableEntries(partPaths)))

  local filename = getPackageThumbnailDiskPath(package.id)
  local uiPath = getPackageThumbnailUiPath(package.id)
  if not filename then
    done(false, "no save path")
    return
  end
  ensureSaveDirectory(filename)

  if not core_vehicle_partmgmt or not core_vehicle_partmgmt.highlightParts then
    done(false, "part highlight API missing")
    return
  end

  local camPos, camRot, fov = frameEngineCamera(vehObj, runtimeData.vdata, partPaths, partNames)
  if not camPos or not camRot then
    done(false, "could not frame engine camera")
    return
  end

  if not render_renderViews or not render_renderViews.takeScreenshot then
    extensions.load("render_renderViews")
  end
  if not render_renderViews or not render_renderViews.takeScreenshot then
    done(false, "render view screenshot missing")
    return
  end

  local jobHandle = core_jobsystem.create(function(job)
    isolated = true
    local highlightOk, highlightErr = pcall(core_vehicle_partmgmt.highlightParts, partPaths, vehId)
    if not highlightOk then
      done(false, "highlightParts failed: " .. tostring(highlightErr))
      return
    end
    job.sleep(0.3)

    local screenshotDone = false
    local screenshotOk, screenshotErr = pcall(function()
      render_renderViews.takeScreenshot({
        renderViewName = "enginePkgThumb",
        screenshotDelay = 0.4,
        resolution = vec3(1000, 562, 0),
        downscaleFactor = 2,
        copyMainViewExposure = false,
        manualEV = 12,
        rot = camRot,
        pos = camPos,
        fov = fov or 32,
        nearPlane = 0.04,
        filename = filename
      }, function(success)
        screenshotDone = true
        local exists = (filename and FS:fileExists(filename)) or (uiPath and FS:fileExists(uiPath))
        if success == true or exists then
          package.thumbnailAt = os.time()
          package.thumbnailCaptureVersion = thumbnailCaptureVersion
          saveData()
          sendUIData()
          done(true)
        else
          done(false, "screenshot callback reported failure")
        end
      end)
    end)

    if not screenshotOk then
      done(false, "takeScreenshot error: " .. tostring(screenshotErr))
      return
    end

    local waitStart = os.clock()
    while not screenshotDone and (os.clock() - waitStart) < 6 do
      job.sleep(0.1)
    end
    if not finished then
      done(false, "screenshot timed out")
    end
  end, 1)
  if jobHandle and jobHandle.setExitCallback then
    jobHandle.setExitCallback(function()
      if not finished then
        done(false, "thumbnail job ended")
      end
    end)
  end
end

local function flushThumbnailWaiters()
  if thumbnailBusy or thumbnailQueue[1] then return end
  local waiters = pendingAfterIdle
  pendingAfterIdle = {}
  for _, waiter in ipairs(waiters) do
    local ok, err = pcall(waiter)
    if not ok then
      log("E", logTag, "Thumbnail idle callback failed: " .. tostring(err))
    end
  end
end

local function pumpThumbnailQueue()
  if thumbnailBusy then return end
  local job = table.remove(thumbnailQueue, 1)
  if not job then
    capturingPackageId = nil
    flushThumbnailWaiters()
    return
  end
  thumbnailBusy = true
  capturingPackageId = job.packageId
  captureEngineThumbnailNow(job.packageId, job.inventoryId, function(ok)
    thumbnailBusy = false
    capturingPackageId = nil
    if job.callback then
      local cbOk, cbErr = pcall(job.callback, ok)
      if not cbOk then
        log("E", logTag, "Queued engine thumbnail callback failed: " .. tostring(cbErr))
      end
    end
    pumpThumbnailQueue()
  end)
end

local function whenThumbnailsIdle(callback)
  if not callback then return end
  if not thumbnailBusy and not thumbnailQueue[1] then
    local ok, err = pcall(callback)
    if not ok then
      log("E", logTag, "Thumbnail idle callback failed: " .. tostring(err))
    end
    return
  end
  table.insert(pendingAfterIdle, callback)
end

local function isThumbnailPending(packageId)
  if capturingPackageId and tostring(capturingPackageId) == tostring(packageId) then
    return true
  end
  for _, job in ipairs(thumbnailQueue) do
    if tostring(job.packageId) == tostring(packageId) then
      return true
    end
  end
  return false
end

local function enqueueEngineThumbnail(package, inventoryId, callback)
  if not package or not inventoryId then
    if callback then callback(false) end
    return
  end
  if isThumbnailPending(package.id) then
    if callback then whenThumbnailsIdle(function() callback(true) end) end
    return
  end
  table.insert(thumbnailQueue, {
    packageId = package.id,
    inventoryId = inventoryId,
    callback = callback
  })
  pumpThumbnailQueue()
end

local function packageNeedsThumbnail(package)
  if not package then return false end
  return not packageThumbnailExists(package.id) or tonumber(package.thumbnailCaptureVersion) ~= thumbnailCaptureVersion
end

local function maybeCaptureMissingThumbnails()
  for _, package in ipairs(packages) do
    if packageNeedsThumbnail(package) then
      local status, installedInventoryId = getPackageStatus(package)
      local inventoryId = installedInventoryId
      if status == "installed" and inventoryId then
        local spawnedId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
        if not spawnedId and tonumber(inventoryId) == tonumber(currentInventoryId) then
          spawnedId = career_modules_inventory.getVehicleIdFromInventoryId(currentInventoryId)
          inventoryId = currentInventoryId
        end
        if spawnedId then
          log("I", logTag, "Queueing engine thumbnail for package " .. tostring(package.id) .. " on vehicle " .. tostring(inventoryId))
          enqueueEngineThumbnail(package, inventoryId)
        end
      end
    end
  end
end

local function validateSelectedVehicle()
  local vehicle = currentInventoryId and career_modules_inventory.getVehicles()[currentInventoryId]
  if not vehicle then return false, "No vehicle is selected." end
  if vehicle.owned ~= true then return false, "The selected vehicle is not owned." end
  if vehicle.timeToAccess then return false, "The selected vehicle is not accessible." end
  if not career_modules_inventory.getVehicleIdFromInventoryId(currentInventoryId) then
    return false, "The selected vehicle is not spawned."
  end
  if not career_modules_insurance_insurance or not career_modules_insurance_insurance.inventoryVehNeedsRepair then
    return false, "Insurance is still loading. Reopen the garage computer."
  end
  if career_modules_insurance_insurance.inventoryVehNeedsRepair(currentInventoryId) then
    return false, "Repair this vehicle before managing engine packages."
  end
  local permission = career_modules_permissions.getStatusForTag({"partSwapping", "vehicleModification"}, {inventoryId = currentInventoryId})
  if not permission.allow then return false, permission.label or "Vehicle modification is not allowed." end
  if vehicleIsElectric(currentInventoryId) then
    return false, "Electric vehicles cannot swap engines."
  end
  return true
end

local function createFromCurrent(name)
  if transactionBusy then return end
  local valid, err = validateSelectedVehicle()
  if not valid then sendResult(false, err) return end
  if findPackageForInventory(currentInventoryId) then
    sendResult(false, "This engine is already grouped as a package.")
    return
  end
  transactionBusy = true
  sendUIData()
  career_modules_inventory.updatePartConditions(nil, currentInventoryId, function()
    local package, captureError = captureCurrentEngineActual(currentInventoryId, name)
    if not package then
      transactionBusy = false
      sendResult(false, captureError)
      return
    end
    career_modules_inventory.setVehicleDirty(currentInventoryId)
    saveData()
    -- Capture while the engine is still on the car. Autosave/UI refresh used
    -- to run first and kill the screenshot (same order store already uses).
    enqueueEngineThumbnail(package, currentInventoryId, function()
      if career_career.isAutosaveEnabled() then career_saveSystem.saveCurrent() end
      transactionBusy = false
      sendResult(true, "Created engine package " .. tostring(package.name) .. ".")
    end)
  end)
end

local function renamePackage(packageId, name)
  if transactionBusy then return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  name = trim(name)
  if name == "" then sendResult(false, "Enter a package name.") return end
  package.name = uniquePackageName(name, package.id)
  package.updatedAt = os.time()
  saveData()
  if career_career.isAutosaveEnabled() then career_saveSystem.saveCurrent() end
  sendResult(true, "Renamed engine package.")
end

local function dismantlePackage(packageId)
  if transactionBusy then return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  local _, installedInventoryId = getPackageStatus(package)
  deletePackageThumbnail(package.id)
  removePackage(package.id, true)
  if installedInventoryId then career_modules_inventory.setVehicleDirty(installedInventoryId) end
  saveData()
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
  sendResult(true, "Dismantled engine package. Its parts are available in My Parts again.")
end

local function storeFuelLevels(vehObj, callback)
  if not vehObj then callback({}) return end
  core_vehicleBridge.requestValue(vehObj, function(data)
    local result = {}
    if data and data[1] then
      for _, tank in ipairs(data[1]) do
        if tank.energyType ~= "n2o" then
          result[tank.name] = {
            currentEnergy = tank.currentEnergy,
            maxEnergy = tank.maxEnergy,
            energyType = tank.energyType,
            relativeFuel = tank.maxEnergy > 0 and tank.currentEnergy / tank.maxEnergy or 0
          }
        end
      end
    end
    callback(result)
  end, "energyStorage")
end

local function restoreFuelLevels(vehObj, storedLevels)
  if not vehObj or not storedLevels or not next(storedLevels) then return end
  core_vehicleBridge.requestValue(vehObj, function(data)
    if not data or not data[1] then return end
    for _, tank in ipairs(data[1]) do
      local stored = storedLevels[tank.name]
      if stored and stored.energyType == tank.energyType then
        local amount = math.min(stored.currentEnergy, tank.maxEnergy)
        if tank.maxEnergy > stored.maxEnergy then amount = tank.maxEnergy * stored.relativeFuel end
        core_vehicleBridge.executeAction(vehObj, "setEnergyStorageEnergy", tank.name, math.max(amount, tank.maxEnergy * 0.05))
      end
    end
  end, "energyStorage")
end

local function storeInstalledPackage(packageId)
  if transactionBusy then return end
  local valid, validationError = validateSelectedVehicle()
  if not valid then sendResult(false, validationError) return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  local status, installedInventoryId = getPackageStatus(package)
  if status ~= "installed" or tonumber(installedInventoryId) ~= tonumber(currentInventoryId) then
    sendResult(false, "Only the selected vehicle's installed engine package can be stored.")
    return
  end

  transactionBusy = true
  sendUIData()
  career_modules_inventory.updatePartConditions(nil, currentInventoryId, function()
    local inventory = getPartInventory()
    local vehicles = career_modules_inventory.getVehicles()
    local vehicle = vehicles[currentInventoryId]
    local runtimeData, oldVehObj = getRuntimeVehicleData(currentInventoryId)
    local engine = runtimeData and runtimeData.config and getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
    if not vehicle or not runtimeData or not oldVehObj or not engine then
      transactionBusy = false
      sendResult(false, "The installed engine could not be read.")
      return
    end

    local currentTree, treeError = makePackageTree(engine.node, currentInventoryId)
    if not currentTree or tostring(currentTree.partId) ~= tostring(package.tree and package.tree.partId) then
      transactionBusy = false
      sendResult(false, treeError or "The installed engine no longer matches this package.")
      return
    end

    local inventorySnapshot = deepcopy(inventory)
    local packagesSnapshot = deepcopy(packages)
    local vehicleSnapshot = deepcopy(vehicle)
    package = captureCurrentEngineActual(currentInventoryId, package.name, package)
    if not package then
      restoreTable(inventory, inventorySnapshot)
      packages = packagesSnapshot
      transactionBusy = false
      sendResult(false, "The installed engine package could not be refreshed.")
      return
    end

    local function continueStore()
    local entries = collectTreePartEntries(package.tree, engine.path)
    local newConditions = deepcopy(vehicle.partConditions or {})

    for _, entry in ipairs(entries) do
      local part = inventory[entry.partId]
      if not part then
        restoreTable(inventory, inventorySnapshot)
        packages = packagesSnapshot
        transactionBusy = false
        sendResult(false, "The engine package is missing one or more parts.")
        return
      end
      if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
      newConditions[part.partPath] = nil
      part.location = 0
      part.mainPart = true
      part.enginePackageId = tostring(package.id)
    end

    engine.node.chosenPartName = ""
    engine.node.children = {}
    engine.node.partPath = nil
    vehicle.config.partsTree = runtimeData.config.partsTree
    vehicle.config.vars = vehicle.config.vars or {}
    for variableName in pairs(package.tuning or {}) do vehicle.config.vars[variableName] = nil end
    vehicle.partConditions = newConditions
    vehicle.partList = nil
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[engine.path] = true
    package.installedInventoryId = nil
    package.updatedAt = os.time()

    local transactionFinished = false
    local function rollback(message)
      if transactionFinished then return end
      transactionFinished = true
      restoreTable(inventory, inventorySnapshot)
      packages = packagesSnapshot
      vehicles[currentInventoryId] = vehicleSnapshot
      if career_modules_partInventory.onPartShoppingTransactionComplete then
        career_modules_partInventory.onPartShoppingTransactionComplete()
      end
      career_modules_inventory.spawnVehicle(currentInventoryId, 2, repairPackageFlags)
      transactionBusy = false
      sendResult(false, message or "Storing the engine failed and was rolled back.")
    end

    storeFuelLevels(oldVehObj, function(fuelLevels)
      local ok, spawnedVehicle = pcall(career_modules_inventory.spawnVehicle, currentInventoryId, 2, function()
        if transactionFinished then return end
        local callbackOk, callbackError = pcall(function()
          local newVehObj = getSpawnedVehicleObject(currentInventoryId)
          restoreFuelLevels(newVehObj, fuelLevels)
          unhideInventoryVehicle(currentInventoryId)
          if career_modules_partInventory.onPartShoppingTransactionComplete then
            career_modules_partInventory.onPartShoppingTransactionComplete()
          end
          repairPackageFlags()
          if career_modules_vehiclePerformance and career_modules_vehiclePerformance.invalidateCertification then
            career_modules_vehiclePerformance.invalidateCertification(currentInventoryId)
          end
          career_modules_inventory.setVehicleDirty(currentInventoryId)
        end)
        if not callbackOk then
          log("E", logTag, "Engine package storage completion failed: " .. tostring(callbackError))
          rollback("The stored engine transaction could not be finalized and was rolled back.")
          return
        end
        transactionFinished = true
        transactionBusy = false
        saveData()
        career_saveSystem.saveCurrent()
        sendResult(true, "Stored " .. tostring(package.name) .. ". Use Part Customization to build another engine.")
      end)
      if not ok then
        log("E", logTag, "Storing engine package failed while rebuilding the vehicle: " .. tostring(spawnedVehicle))
      end
      if not ok or not spawnedVehicle then rollback("The vehicle could not be rebuilt without the stored engine.") end
      if ok and spawnedVehicle and core_jobsystem then
        core_jobsystem.create(function(job)
          job.sleep(15)
          if not transactionFinished then rollback("The vehicle rebuild timed out and was rolled back.") end
        end, 1)
      end
    end)
    end

    if packageNeedsThumbnail(package) then
      enqueueEngineThumbnail(package, currentInventoryId)
    end
    whenThumbnailsIdle(continueStore)
  end)
end

local function installPackage(packageId)
  if transactionBusy then return end
  local valid, validationError = validateSelectedVehicle()
  if not valid then sendResult(false, validationError) return end
  local targetPackage = getPackageById(packageId)
  if not targetPackage then sendResult(false, "Engine package not found.") return end
  local status = getPackageStatus(targetPackage)
  if status ~= "stored" then sendResult(false, "Only stored engine packages can be installed.") return end

  local targetCandidate, fitError = findCompatibleTarget(targetPackage, currentInventoryId)
  if not targetCandidate then sendResult(false, fitError) return end

  transactionBusy = true
  sendUIData()
  career_modules_inventory.updatePartConditions(nil, currentInventoryId, function()
    local inventory = getPartInventory()
    local vehicles = career_modules_inventory.getVehicles()
    local vehicle = vehicles[currentInventoryId]
    local runtimeData, oldVehObj = getRuntimeVehicleData(currentInventoryId)
    if not vehicle or not runtimeData or not oldVehObj then
      transactionBusy = false
      sendResult(false, "The selected vehicle is no longer available.")
      return
    end

    local inventorySnapshot = deepcopy(inventory)
    local packagesSnapshot = deepcopy(packages)
    local vehicleSnapshot = deepcopy(vehicle)

    local outgoingPackage
    local currentEngine = getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
    if currentEngine then
      outgoingPackage = findPackageForInventory(currentInventoryId)
      local outgoingName = outgoingPackage and outgoingPackage.name or nil
      outgoingPackage, validationError = captureCurrentEngineActual(currentInventoryId, outgoingName, outgoingPackage)
      if not outgoingPackage then
        transactionBusy = false
        sendResult(false, validationError)
        return
      end
    end

    local outgoingEntries = outgoingPackage and collectTreePartEntries(outgoingPackage.tree, targetCandidate.path) or {}
    local incomingEntries = collectTreePartEntries(targetPackage.tree, targetCandidate.path)
    local newConditions = deepcopy(vehicle.partConditions or {})

    for _, entry in ipairs(outgoingEntries) do
      local part = inventory[entry.partId]
      if part then
        if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
        newConditions[part.partPath] = nil
        part.location = 0
        part.mainPart = true
        part.enginePackageId = tostring(outgoingPackage.id)
      end
    end

    local targetModel = vehicle.model
    local availableParts = jbeamIO.getAvailableParts(runtimeData.ioCtx)
    for _, entry in ipairs(incomingEntries) do
      local part = inventory[entry.partId]
      if not part or tonumber(part.location) ~= 0 then
        restoreTable(inventory, inventorySnapshot)
        packages = packagesSnapshot
        transactionBusy = false
        sendResult(false, "An engine package part became unavailable during the swap.")
        return
      end
      part.location = currentInventoryId
      part.containingSlot = entry.containingSlot
      part.partPath = entry.partPath
      part.vehicleModel = targetModel
      part.description = availableParts[entry.name] or part.description
      part.mainPart = true
      part.enginePackageId = tostring(targetPackage.id)
      newConditions[entry.partPath] = deepcopy(part.partCondition or {integrityValue = 1, visualValue = 1, odometer = 0})
    end

    targetCandidate.node.chosenPartName = targetPackage.tree.name
    targetCandidate.node.children = makeConfigTree(targetPackage.tree, targetCandidate.path).children
    targetCandidate.node.path = targetCandidate.path
    targetCandidate.node.partPath = targetCandidate.path .. targetPackage.tree.name
    vehicle.config.partsTree = runtimeData.config.partsTree
    vehicle.config.vars = vehicle.config.vars or {}
    if outgoingPackage then
      for variableName in pairs(outgoingPackage.tuning or {}) do vehicle.config.vars[variableName] = nil end
    end
    for variableName, value in pairs(targetPackage.tuning or {}) do vehicle.config.vars[variableName] = value end
    vehicle.partConditions = newConditions
    vehicle.partList = nil
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[targetCandidate.path] = true

    if outgoingPackage then
      outgoingPackage.installedInventoryId = nil
      outgoingPackage.updatedAt = os.time()
    end
    targetPackage.installedInventoryId = currentInventoryId
    targetPackage.lastInstalledModel = targetModel
    targetPackage.rootSlotName = targetCandidate.slotName
    targetPackage.rootPath = targetCandidate.path
    targetPackage.updatedAt = os.time()

    local transactionFinished = false
    local function rollback(message)
      if transactionFinished then return end
      transactionFinished = true
      restoreTable(inventory, inventorySnapshot)
      packages = packagesSnapshot
      vehicles[currentInventoryId] = vehicleSnapshot
      if career_modules_partInventory.onPartShoppingTransactionComplete then
        career_modules_partInventory.onPartShoppingTransactionComplete()
      end
      career_modules_inventory.spawnVehicle(currentInventoryId, 2, repairPackageFlags)
      transactionBusy = false
      sendResult(false, message or "The engine swap failed and was rolled back.")
    end

    storeFuelLevels(oldVehObj, function(fuelLevels)
      local ok, spawnedVehicle = pcall(career_modules_inventory.spawnVehicle, currentInventoryId, 2, function()
        if transactionFinished then return end
        local callbackOk, callbackError = pcall(function()
          local newVehObj = getSpawnedVehicleObject(currentInventoryId)
          restoreFuelLevels(newVehObj, fuelLevels)
          unhideInventoryVehicle(currentInventoryId)
          if career_modules_partInventory.onPartShoppingTransactionComplete then
            career_modules_partInventory.onPartShoppingTransactionComplete()
          end
          repairPackageFlags()
          if career_modules_vehiclePerformance and career_modules_vehiclePerformance.invalidateCertification then
            career_modules_vehiclePerformance.invalidateCertification(currentInventoryId)
          end
          career_modules_inventory.setVehicleDirty(currentInventoryId)
        end)
        if not callbackOk then
          log("E", logTag, "Engine swap completion failed: " .. tostring(callbackError))
          rollback("The rebuilt vehicle could not be finalized; the engine swap was rolled back.")
          return
        end
        transactionFinished = true
        transactionBusy = false
        saveData()
        career_saveSystem.saveCurrent()
        local successMessage = "Installed " .. tostring(targetPackage.name) .. "."
        if outgoingPackage then
          successMessage = successMessage .. " The outgoing engine was stored as " .. tostring(outgoingPackage.name) .. "."
        end
        sendResult(true, successMessage)
        if packageNeedsThumbnail(targetPackage) then
          enqueueEngineThumbnail(targetPackage, currentInventoryId)
        end
      end)
      if not ok then
        log("E", logTag, "Installing engine package failed while rebuilding the vehicle: " .. tostring(spawnedVehicle))
      end
      if not ok or not spawnedVehicle then rollback("The vehicle could not be rebuilt; the engine swap was rolled back.") end
      if ok and spawnedVehicle and core_jobsystem then
        core_jobsystem.create(function(job)
          job.sleep(15)
          if not transactionFinished then
            rollback("The vehicle rebuild timed out; the engine swap was rolled back.")
          end
        end, 1)
      end
    end)
  end)
end

local function refreshInstalledPackage(inventoryId, refreshTree)
  local package = findPackageForInventory(inventoryId)
  if not package then return false end
  local runtimeData = getRuntimeVehicleData(inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if not runtimeData or not vehicle then return false end
  if refreshTree then
    local engine = runtimeData.config and getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
    local currentTree = engine and makePackageTree(engine.node, inventoryId)
    if not currentTree or tostring(currentTree.partId) ~= tostring(package.tree and package.tree.partId) then
      package.installedInventoryId = nil
      package.updatedAt = os.time()
      local inventory = getPartInventory()
      for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
        local part = inventory[partId]
        if part and tonumber(part.location) == tonumber(inventoryId) then
          part.enginePackageId = nil
          part.mainPart = part.containingSlot == "/"
        end
      end
      return true
    end
    local refreshed = captureCurrentEngineActual(inventoryId, package.name, package)
    return refreshed ~= nil
  end
  package.tuning = captureTuning(package.tree, runtimeData, vehicle.config)
  package.updatedAt = os.time()
  return true
end

local function onPartShoppingTransactionComplete()
  if transactionBusy then return end
  local changed = false
  for _, package in ipairs(packages) do
    local inventoryId = tonumber(package.installedInventoryId)
    if inventoryId and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
      changed = refreshInstalledPackage(inventoryId, true) or changed
    end
  end
  if changed then saveData() end
  sendUIData()
end

local function onCareerTuningApplied()
  if transactionBusy then return end
  local inventoryId = career_modules_inventory.getCurrentVehicle()
  if inventoryId and refreshInstalledPackage(inventoryId, false) then saveData() end
  sendUIData()
end

local function onVehicleRemoved(inventoryId)
  for index = #packages, 1, -1 do
    if tonumber(packages[index].installedInventoryId) == tonumber(inventoryId) then
      table.remove(packages, index)
    end
  end
  saveData()
  sendUIData()
end

local function requestData()
  sendUIData()
  maybeCaptureMissingThumbnails()
  return buildUIData()
end

local function openMenu(inventoryId, computerId)
  currentInventoryId = tonumber(inventoryId)
  originComputerId = tonumber(computerId) or computerId
  if not currentInventoryId then return false end
  menuOpen = true
  extensions.ui_router.navigate("career.computer.enginePackages")
  maybeCaptureMissingThumbnails()
  if core_jobsystem then
    core_jobsystem.create(function(job)
      job.sleep(0.8)
      if menuOpen then maybeCaptureMissingThumbnails() end
    end, 1)
  end
  return true
end

local function closeMenu()
  menuOpen = false
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    if computer then
      career_modules_computer.openMenu(computer)
      currentInventoryId = nil
      originComputerId = nil
      return
    end
  end
  currentInventoryId = nil
  originComputerId = nil
  career_career.closeAllMenus()
end

local function onComputerAddFunctions(menuData, computerFunctions)
  local computerId = menuData.computerFacility and menuData.computerFacility.id
  local garageId = computerId and career_modules_garageManager.computerIdToGarageId(computerId)
  if not garageId or not career_modules_garageManager.isPurchasedGarage(garageId) then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local inventoryId = vehicleData.inventoryId
    local vehicle = career_modules_inventory.getVehicles()[inventoryId]
    local data = {
      id = "enginePackages",
      label = "Engine Packages",
      routeTarget = "career.computer.enginePackages",
      callback = function(callbackComputerId)
        openMenu(inventoryId, callbackComputerId or computerId)
      end,
      order = 6
    }
    if not vehicle or vehicle.owned ~= true or vehicle.timeToAccess or not career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
      data.disabled = true
      data.reason = {type = "text", label = "The vehicle must be owned, accessible, and spawned."}
    elseif vehicleIsElectric(inventoryId) then
      data.disabled = true
      data.reason = {type = "text", label = "Electric vehicles cannot swap engines."}
    elseif vehicleData.needsRepair then
      data.disabled = true
      data.reason = career_modules_computer.reasons.needsRepair
    else
      local permission = career_modules_permissions.getStatusForTag({"partSwapping", "vehicleModification"}, {inventoryId = inventoryId})
      if not permission.allow then data.disabled = true end
      if permission.permission ~= "allowed" then data.reason = permission end
    end
    computerFunctions.vehicleSpecific[inventoryId][data.id] = data
  end
end

local function onSaveCurrentProfile(currentSavePath)
  saveData(currentSavePath)
end

local function initialize()
  if loaded then return end
  loadData()
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  initialize()
end

local function onCareerActivated()
  initialize()
end

local function onCareerModulesActivated()
  initialize()
end

M.openMenu = openMenu
M.requestData = requestData
M.createFromCurrent = createFromCurrent
M.renamePackage = renamePackage
M.installPackage = installPackage
M.storeInstalledPackage = storeInstalledPackage
M.dismantlePackage = dismantlePackage
M.closeMenu = closeMenu

M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onCareerModulesActivated = onCareerModulesActivated
M.onComputerAddFunctions = onComputerAddFunctions
M.onPartShoppingTransactionComplete = onPartShoppingTransactionComplete
M.onCareerTuningApplied = onCareerTuningApplied
M.onVehicleRemoved = onVehicleRemoved
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
