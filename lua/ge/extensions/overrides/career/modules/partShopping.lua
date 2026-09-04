-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"career_career", "gameplay_achievement"}
local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local salesTax = 0.07

local shoppingSessionActive = false
local initialVehicle
local previewVehicle
local shoppingCart

local partsInShop = {}
local currentVehicle
local partShopId = 0
local slotToPartIdMap
local slotsNiceName = {}
local partsNiceName = {}
local previewVehicleSlotData = {}

local currentRouteCategory = ""
local currentRouteSlotPath = ""
local currentRoutePanel = "categories"

local tether -- tether object for aborting shopping when walking too far away

local saveForLaterEnabled = false
local restoreQueue = {}
local restoreInProgress = false
local restoreTotal = 0
local restoreCurrent = 0
local RESTORE_SETTLE_TIME = 0.4
local MAX_ADDITIONAL_PART_PASSES = 32
local warnedDeclaredDefaultMismatches = {}

local sendShoppingDataToUI
local installPart
local removePart

local CART_DRAFT_VERSION = 2
-- In-memory backup so same-session reopen still works if the file write fails.
local memoryCartDrafts = {}

local function toBool(value)
  return value == true or value == 1 or value == "true" or value == "1"
end

local function getCartDraftPath()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  -- Write beside other career/*.json files (marketplace, inventory, etc).
  -- The old nested career/rls_career/ path often did not exist yet, so drafts
  -- silently failed to save.
  return currentSavePath .. "/career/partShoppingCartDrafts.json"
end

local function getLegacyCartDraftPath()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return nil
  end
  return currentSavePath .. "/career/rls_career/partShoppingCartDrafts.json"
end

local function inventoryIdToDraftKey(inventoryId)
  return tostring(inventoryId)
end

local function draftPartsCount(parts)
  if type(parts) ~= "table" then
    return 0
  end
  local count = 0
  for _ in pairs(parts) do
    count = count + 1
  end
  return count
end

local function normalizeDraftParts(parts)
  if type(parts) ~= "table" then
    return {}
  end
  -- jsonReadFile sometimes returns arrays as string-keyed maps; normalize to a
  -- dense array so ipairs / # work during restore.
  local normalized = {}
  local maxIndex = 0
  for key, value in pairs(parts) do
    local index = tonumber(key)
    if index and type(value) == "table" then
      normalized[index] = value
      if index > maxIndex then
        maxIndex = index
      end
    end
  end
  if maxIndex == 0 then
    return {}
  end
  local dense = {}
  for i = 1, maxIndex do
    if normalized[i] then
      table.insert(dense, normalized[i])
    end
  end
  return dense
end

local function newEmptyCartDraftStore()
  return { version = CART_DRAFT_VERSION, drafts = {} }
end

local function writeCartDraftStore(store)
  local filePath = getCartDraftPath()
  if not filePath or not store then
    return false
  end
  if not store.drafts or not next(store.drafts) then
    if FS:fileExists(filePath) then
      FS:removeFile(filePath)
    end
    local legacyPath = getLegacyCartDraftPath()
    if legacyPath and FS:fileExists(legacyPath) then
      FS:removeFile(legacyPath)
    end
    return true
  end
  local ok = career_saveSystem.jsonWriteFileSafe(filePath, store, true)
  if not ok then
    log("E", "partShopping", "Failed to write cart draft file: " .. tostring(filePath))
  end
  return ok and true or false
end

local function pruneStaleCartDrafts(store)
  if not store or not store.drafts then
    return false
  end
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles then
    return false
  end
  local changed = false
  for key, _ in pairs(store.drafts) do
    local inventoryId = tonumber(key)
    if not inventoryId or not vehicles[inventoryId] then
      store.drafts[key] = nil
      memoryCartDrafts[key] = nil
      changed = true
    end
  end
  return changed
end

local function readCartDraftStoreFromPath(filePath)
  if not filePath or not FS:fileExists(filePath) then
    return nil
  end
  local data = jsonReadFile(filePath)
  if not data or type(data.drafts) ~= "table" then
    return nil
  end
  return { version = CART_DRAFT_VERSION, drafts = data.drafts }
end

local function loadAllCartDrafts()
  local store = readCartDraftStoreFromPath(getCartDraftPath())
  if not store then
    -- Migrate drafts saved under the old nested path.
    store = readCartDraftStoreFromPath(getLegacyCartDraftPath())
    if store then
      writeCartDraftStore(store)
    end
  end
  if not store then
    return newEmptyCartDraftStore()
  end
  if pruneStaleCartDrafts(store) then
    writeCartDraftStore(store)
  end
  return store
end

local function loadCartDraftForVehicle(inventoryId)
  if not inventoryId then
    return nil
  end
  local key = inventoryIdToDraftKey(inventoryId)
  local memoryEntry = memoryCartDrafts[key]
  if memoryEntry and draftPartsCount(memoryEntry.parts) > 0 then
    return {
      parts = normalizeDraftParts(memoryEntry.parts),
      savedAt = memoryEntry.savedAt,
    }
  end
  local entry = loadAllCartDrafts().drafts[key]
  if not entry then
    return nil
  end
  local parts = normalizeDraftParts(entry.parts)
  if draftPartsCount(parts) == 0 then
    return nil
  end
  return { parts = parts, savedAt = entry.savedAt }
end

local function clearCartDraftForVehicle(inventoryId)
  if not inventoryId then
    return
  end
  local key = inventoryIdToDraftKey(inventoryId)
  memoryCartDrafts[key] = nil
  local store = loadAllCartDrafts()
  if not store.drafts[key] then
    return
  end
  store.drafts[key] = nil
  writeCartDraftStore(store)
end

local function getSlotPathDepth(slotPath)
  if not slotPath then
    return 0
  end
  local depth = 0
  for _ in string.gmatch(slotPath, "[^/]+") do
    depth = depth + 1
  end
  return depth
end

local function sortRestoreEntries(entries)
  table.sort(entries, function(a, b)
    local depthA = getSlotPathDepth(a.containingSlot)
    local depthB = getSlotPathDepth(b.containingSlot)
    if depthA ~= depthB then
      return depthA < depthB
    end
    return (a.containingSlot or "") < (b.containingSlot or "")
  end)
  return entries
end

local function serializePartsInForDraft()
  local parts = {}
  if not shoppingCart or not shoppingCart.partsIn then
    return parts
  end
  for containingSlot, part in pairs(shoppingCart.partsIn) do
    table.insert(parts, {
      containingSlot = containingSlot,
      name = part.name,
      partId = part.partId,
      emptyPlaceholder = part.emptyPlaceholder or false,
    })
  end
  return sortRestoreEntries(parts)
end

local function persistCartDraftToFile()
  if not currentVehicle or not shoppingCart then
    return
  end
  local parts = serializePartsInForDraft()
  local key = inventoryIdToDraftKey(currentVehicle)
  if #parts == 0 then
    clearCartDraftForVehicle(currentVehicle)
    return
  end
  local entry = {
    parts = parts,
    savedAt = os.time(),
  }
  memoryCartDrafts[key] = entry
  local store = loadAllCartDrafts()
  store.drafts[key] = entry
  writeCartDraftStore(store)
end

local function isSlotAlreadySatisfied(entry)
  if not entry or not shoppingCart or not shoppingCart.partsIn then
    return false
  end
  local existing = shoppingCart.partsIn[entry.containingSlot]
  if not existing then
    return false
  end
  if entry.emptyPlaceholder then
    return existing.emptyPlaceholder == true
  end
  if entry.partId then
    return existing.name == entry.name and existing.partId == entry.partId
  end
  return existing.name == entry.name and not existing.emptyPlaceholder
end

local function findPartInShopForRestoreEntry(entry)
  if not entry then
    return nil
  end
  for _, part in ipairs(partsInShop) do
    if part.containingSlot ~= entry.containingSlot then
      goto continue
    end
    if entry.emptyPlaceholder then
      if part.emptyPlaceholder then
        return part
      end
    else
      if part.emptyPlaceholder then
        goto continue
      end
      if part.name ~= entry.name then
        goto continue
      end
      if entry.partId then
        if part.partId == entry.partId then
          return part
        end
      elseif not part.partId then
        return part
      end
    end
    ::continue::
  end
  return nil
end

local function abortCartRestore()
  restoreQueue = {}
  restoreInProgress = false
  restoreTotal = 0
  restoreCurrent = 0
end

local processNextRestorePart

local function startCartRestore(parts)
  abortCartRestore()
  local entries = sortRestoreEntries(deepcopy(parts or {}))
  restoreQueue = {}
  for _, entry in ipairs(entries) do
    if not isSlotAlreadySatisfied(entry) then
      table.insert(restoreQueue, entry)
    end
  end
  restoreTotal = #restoreQueue
  restoreCurrent = 0
  if restoreTotal == 0 then
    return
  end
  restoreInProgress = true
  sendShoppingDataToUI()
  processNextRestorePart()
end

processNextRestorePart = function()
  if not restoreInProgress then
    return
  end
  while #restoreQueue > 0 do
    local entry = table.remove(restoreQueue, 1)
    if not isSlotAlreadySatisfied(entry) then
      local matched = findPartInShopForRestoreEntry(entry)
      if matched then
        if matched.emptyPlaceholder then
          removePart(matched)
        else
          installPart(matched)
        end
        return
      end
    end
  end
  restoreInProgress = false
  restoreCurrent = restoreTotal
  sendShoppingDataToUI()
end

local function maybeStartCartRestore()
  local draft = loadCartDraftForVehicle(currentVehicle)
  if not draft then
    saveForLaterEnabled = false
    return
  end
  saveForLaterEnabled = true
  startCartRestore(draft.parts)
end

local function setSaveForLater(enabled)
  saveForLaterEnabled = toBool(enabled)
  if saveForLaterEnabled then
    if shoppingSessionActive then
      persistCartDraftToFile()
    end
  else
    clearCartDraftForVehicle(currentVehicle)
  end
  if shoppingSessionActive then
    sendShoppingDataToUI()
  end
  return true
end

local function getSaveForLater()
  return saveForLaterEnabled
end

-- TODO it needs to be decided, which parts come with their own subparts when you buy them and which parts you can use the existing subparts of the vehicle for
-- for now, i will assume that parts come with default subparts, except when a fitting part is already in the vehicle

local function openUIState()
  -- TODO we send all data every time a part changes. we should send only smaller updates
  extensions.ui_router.navigate("career.computer.partShopping")
end

local function flattenPartsTree(tree)
  local result = {}

  if tree.chosenPartName then
    result[tree.path] = tree.chosenPartName
  end

  if tree.children then
    for slotName, childNode in pairs(tree.children) do
      tableMerge(result, flattenPartsTree(childNode))
    end
  end

  return result
end

local function getNodeFromSlotPath(tree, path)
  if not tree or not path then return nil end

  -- Handle empty path case
  if path == "/" then return tree end

  -- Split the path into segments
  local segments = {}
  for segment in string.gmatch(path, "[^/]+") do
    table.insert(segments, segment)
  end

  -- Navigate through the tree
  local currentNode = tree
  for _, segment in ipairs(segments) do
    if currentNode.children and currentNode.children[segment] then
      currentNode = currentNode.children[segment]
    else
      return nil -- Path not found
    end
  end

  return currentNode
end

local function getCurrentVehicleVehId()
  if not currentVehicle then return end
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(currentVehicle)
  return vehId
end

local function getCurrentVehicleObj()
  if not currentVehicle then return end
  return getObjectByID(getCurrentVehicleVehId())
end

local function isCargoLogisticsMaterialsUnlocked()
  career_branches.checkUnlocks()
  return career_branches.getBranchByPath('logistics-materials').unlocked
end

local function generatePart(partName, currentVehicleData, availableParts, path, slot, vehicleObj)
  local jbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, partName)
  if not jbeamData then return end
  local part = {}
  part.name = partName
  part.value = jbeamData.information.value or 100
  part.partCondition = {integrityValue = 1, odometer = 0, visualValue = 1}
  part.description = availableParts[partName] or {description = _tr("ui.career.partShopping.noDescriptionFound")}
  part.tags = {}
  part.containingSlot = path
  part.partPath = path .. partName
  part.slot = slot
  --part.slotType = jbeamData.slotType
  part.vehicleModel = vehicleObj:getJBeamFilename()
  part.year = 2023
  part.partShopId = partShopId

  if part.description and part.description.description then
    part.description.description = core_vehicle_partmgmt.getTranslation(
      part.description.description,
      "ui.vehicleconfig.information.name."
    )
  end

  if jbeamData.cargoStorage and not isCargoLogisticsMaterialsUnlocked() and jbeamData.information.name ~= "Magic Cargo Testing Part" then
    for i=2, tableSize(jbeamData.cargoStorage) do
      for _, cargoType in ipairs(jbeamData.cargoStorage[i][3]) do
        if cargoType == "dryBulk" or cargoType == "fluid" then
          part.disabled = true
          part.disabledReason = _tr("ui.career.partShopping.cargoLogisticsNotUnlocked")
          break
        end
      end
    end
  end
  partShopId = partShopId + 1

  part.finalValue = math.max(roundNear(career_modules_valueCalculator.getPartValue(part), 5) - 0.01, 0)
  return part
end

local function getPartSlotFromPartIdInShoppingCart(partId)
  for _, part in pairs(shoppingCart.partsIn) do
    if part.partId == partId then
      return part.containingSlot
    end
  end
end

local function generatePartFromTree(treeNode, slotName, slotInfo, currentVehicleData, availableParts, vehicleObj)
  if not treeNode then return end

  local partInfo = availableParts[treeNode.chosenPartName]
  previewVehicleSlotData[treeNode.path] = slotInfo

  treeNode.chosenPartNiceName = partInfo and partInfo.description
  treeNode.slotNiceName = slotsNiceName[slotName]
  treeNode.slotName = slotName

  partsNiceName[treeNode.chosenPartName] = treeNode.chosenPartNiceName

  if treeNode.suitablePartNames then
    for _, suitablePartName in ipairs(treeNode.suitablePartNames) do
      local part = generatePart(suitablePartName, currentVehicleData, availableParts, treeNode.path, slotName, vehicleObj)
      if part and part.containingSlot ~= "main" and not part.description.isAuxiliary then
        table.insert(partsInShop, part)

        -- Add matching parts from inventory
        for partId, inventoryPart in pairs(career_modules_partInventory.getInventory()) do
          local partSlotOfThisPartInShoppingCart = getPartSlotFromPartIdInShoppingCart(partId)
          if not inventoryPart.enginePackageId and inventoryPart.name == suitablePartName and inventoryPart.location == 0 and inventoryPart.vehicleModel == part.vehicleModel and (not partSlotOfThisPartInShoppingCart or partSlotOfThisPartInShoppingCart == part.containingSlot) then
            local shopPart = deepcopy(inventoryPart)
            shopPart.containingSlot = part.containingSlot
            shopPart.partPath = part.partPath
            shopPart.slot = slotName
            shopPart.vehicleModel = part.vehicleModel
            shopPart.partId = partId
            shopPart.partShopId = partShopId
            partShopId = partShopId + 1
            shopPart.finalValue = 0
            table.insert(partsInShop, shopPart)
          end
        end
      end
    end
  end

  if slotInfo and not slotInfo.coreSlot and initialVehicle.partList[treeNode.path] and initialVehicle.partList[treeNode.path] ~= "" then
    local emptyPart = {}
    emptyPart.name = "empty"
    emptyPart.description = {}
    emptyPart.description.description = core_locales.contextTranslate("ui.career.partShopping.removePart", {partName = partsNiceName[initialVehicle.partList[treeNode.path]]})
    emptyPart.emptyPlaceholder = true
    emptyPart.containingSlot = treeNode.path
    emptyPart.partPath = treeNode.path .. "empty"
    emptyPart.slot = slotName
    emptyPart.slotNiceName = slotsNiceName[slotName]
    emptyPart.partShopId = partShopId
    emptyPart.finalValue = 0
    partShopId = partShopId + 1
    table.insert(partsInShop, emptyPart)
  end

  -- Recursively process child slots
  if treeNode.children then
    for childSlot, childNode in pairs(treeNode.children) do
      local childSlotInfo = partInfo and partInfo.slotInfoUi and partInfo.slotInfoUi[childSlot]
      generatePartFromTree(childNode, childSlot, childSlotInfo, currentVehicleData, availableParts, vehicleObj)
    end
  end
end

local function generatePartShop()
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)
  local vehicleObj = getCurrentVehicleObj()
  previewVehicleSlotData = {}

  for partName, partInfo in pairs(availableParts) do
    if partInfo.slotInfoUi then
      for slotName, slotInfo in pairs(partInfo.slotInfoUi) do
        slotsNiceName[slotName] = core_vehicle_partmgmt.getTranslation(slotInfo.description, "ui.vehicleconfig.slot.description.")
      end
    end
  end

  partsInShop = {}
  local chosenPartsTree = deepcopy(currentVehicleData.config.partsTree)
  generatePartFromTree(chosenPartsTree, "", nil, currentVehicleData, availableParts, vehicleObj)

  return chosenPartsTree
end

local function buildSearchSlotList(partTree)
  local searchSlotDict = {}

  -- Helper function to traverse the part tree
  local function traverseTree(node, slotName)
    if not node then return end

    if slotName then
      -- Build nice path by walking up the tree
      local pathSegments = {}
      local currentPath = node.path

      -- Split path into segments and process each one
      for segment in currentPath:gmatch("([^/]+)/") do
        table.insert(pathSegments, slotsNiceName[segment] or segment)
      end

      -- Add slot data for current node
      local slotData = {
        slotName = slotName,
        slotNiceName = slotsNiceName[slotName],
        path = node.path,
        nicePath = table.concat(pathSegments, " > "),
        partNiceName = partsNiceName[node.chosenPartName]
      }
      searchSlotDict[node.path] = slotData
    end

    -- Recursively process children
    if node.children then
      for childSlot, childNode in pairs(node.children) do
        traverseTree(childNode, childSlot)
      end
    end
  end

  -- Start traversal from root
  traverseTree(partTree)

  -- Convert dict to sorted list
  local searchSlotList = {}
  for path, slotInfo in pairs(searchSlotDict) do
    table.insert(searchSlotList, slotInfo)
  end
  table.sort(searchSlotList, function(a,b) return a.slotNiceName < b.slotNiceName end)
  return searchSlotList
end

local function updateShoppingCart()
  shoppingCart.total = 0
  shoppingCart.partsInList = {}
  shoppingCart.partsOutList = {}
  shoppingCart.partsOut = {}
  shoppingCart.slotList = {}

  for path, part in pairs(shoppingCart.partsIn) do
    shoppingCart.partsOut[path] = career_modules_partInventory.getInventory()[slotToPartIdMap[currentVehicle][path]]
  end
  for path, partName in pairs(initialVehicle.partList) do
    if partName ~= "" and (not previewVehicle.partList[path] or previewVehicle.partList[path] == "") then
      shoppingCart.partsOut[path] = career_modules_partInventory.getInventory()[slotToPartIdMap[currentVehicle][path]]
    end
  end

  -- Convert the partsIn/partsOut tables to lists
  local slotsAdded = {}
  local counter = 1
  for slot, part in pairs(shoppingCart.partsIn) do
    shoppingCart.slotList[counter] = slot
    shoppingCart.partsInList[counter] = part
    shoppingCart.partsOutList[counter] = shoppingCart.partsOut[part.containingSlot]
    slotsAdded[part.containingSlot] = true
    counter = counter + 1
  end

  for slot, part in pairs(shoppingCart.partsOut) do
    if not slotsAdded[part.containingSlot] then
      shoppingCart.slotList[counter] = slot
      shoppingCart.partsOutList[counter] = part
      slotsAdded[part.containingSlot] = true
      counter = counter + 1
    end
  end

  -- Calculate the total price of the whole shopping cart
  local total = 0
  for slot, part in pairs(shoppingCart.partsIn) do
    total = total + part.finalValue
  end

  shoppingCart.taxes = total * salesTax
  shoppingCart.total = total + shoppingCart.taxes
end

-- Normalize a router route into the part shopping selection (category, slot path,
-- visible panel). Mirrors the panel decision the Vue route used to make from
-- route.name/params: the slot route always shows the parts list, the category
-- route shows the parts list for cargo and the slot list otherwise, and the root
-- shows the categories.
local function normalizeRouteSelection(toRoute)
  local name = type(toRoute) == "table" and toRoute.name or nil
  local params = type(toRoute) == "table" and toRoute.params or nil

  local category = ""
  local slotPath = ""
  if type(params) == "table" then
    if type(params.category) == "string" then
      category = params.category
    end
    -- slotPath is a node path string ("main/engine/"); the catch-all route may
    -- also deliver it as an array of segments.
    local sp = params.slotPath
    if type(sp) == "string" then
      slotPath = sp
    elseif type(sp) == "table" then
      slotPath = table.concat(sp, "/")
    end
  end

  local panel = "categories"
  if name == "career.computer.partShopping.category.slot" then
    panel = "parts"
  elseif name == "career.computer.partShopping.category" then
    panel = (category == "cargo") and "parts" or "slots"
  end

  return category, slotPath, panel
end

-- Build the parts list for the active route selection. Replicates the Vue
-- store's filterParts: cargo filters by the "cargo_load" name, every other
-- category filters by the selected slot path (containingSlot match).
local function buildFilteredParts(category, slotPath)
  local result = {}
  for _, part in ipairs(partsInShop) do
    if part.slot then
      if category == "cargo" then
        if part.name and string.find(part.name, "cargo_load", 1, true) then
          result[#result + 1] = part
        end
      elseif slotPath ~= "" and part.containingSlot == slotPath then
        result[#result + 1] = part
      end
    end
  end

  -- Same ordering as the Vue store: empty placeholders first, then inventory
  -- parts (partId), then alphabetical by description.
  table.sort(result, function(a, b)
    local aEmpty = a.emptyPlaceholder == true
    local bEmpty = b.emptyPlaceholder == true
    if aEmpty ~= bEmpty then return aEmpty end
    local aHasId = a.partId ~= nil
    local bHasId = b.partId ~= nil
    if aHasId ~= bHasId then return aHasId end
    local aDesc = (a.description and a.description.description) or ""
    local bDesc = (b.description and b.description.description) or ""
    return aDesc < bDesc
  end)

  return result
end

sendShoppingDataToUI = function()
  local partTree = generatePartShop()
  local shoppingData = {}
  shoppingData.partsInShop = partsInShop
  shoppingData.partTree = partTree
  shoppingData.shoppingCart = shoppingCart
  shoppingData.slotsNiceName = slotsNiceName
  shoppingData.searchSlotList = buildSearchSlotList(partTree)
  shoppingData.vehicleSlotToPartMap = {}
  for partId, part in pairs(career_modules_partInventory.getInventory()) do
    if part.location == currentVehicle then
      shoppingData.vehicleSlotToPartMap[part.containingSlot] = part
    end
  end

  -- Route-selected fields so Vue renders the active route view directly instead
  -- of recomputing category/slot from route params.
  shoppingData.category = currentRouteCategory
  shoppingData.slot = currentRouteSlotPath
  shoppingData.activePanel = currentRoutePanel
  shoppingData.filteredParts = buildFilteredParts(currentRouteCategory, currentRouteSlotPath)
  -- filteredSlots is search-driven and stays UI-local; emit empty so the route
  -- payload shape is complete. ponytail: search filtering remains in Vue.
  shoppingData.filteredSlots = {}

  shoppingData.playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  shoppingData.saveForLater = saveForLaterEnabled
  shoppingData.restoreInProgress = restoreInProgress
  if restoreInProgress then
    shoppingData.restoreProgress = {
      current = restoreCurrent,
      total = restoreTotal,
    }
  end
  guihooks.trigger("partShoppingData", shoppingData)
end

-- Router lifecycle: store the normalized selection on enter so any emission
-- between enter and mount uses the correct route state.
local function onRouteEnter(context, toRoute, fromRoute, data)
  currentRouteCategory, currentRouteSlotPath, currentRoutePanel = normalizeRouteSelection(toRoute)
end

-- Router lifecycle: re-normalize and emit the route-aware shopping data once the
-- destination view has mounted.
local function onRouteMount(context, toRoute, fromRoute, data)
  currentRouteCategory, currentRouteSlotPath, currentRoutePanel = normalizeRouteSelection(toRoute)
  sendShoppingDataToUI()
end

local function updatePreviewVehicle(currentPartConditions)
  if not shoppingSessionActive then
    return false
  end
  -- get the data
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  if not currentVehicleData then
    log('E', 'inventory', 'unable to get vehicle data')
    return false
  end
  if not currentVehicle then return end

  previewVehicle.config.partsTree = deepcopy(currentVehicleData.config.partsTree)
  previewVehicle.partList = flattenPartsTree(previewVehicle.config.partsTree)
  if currentPartConditions then
    previewVehicle.partConditions = currentPartConditions
  end
  updateShoppingCart()
  sendShoppingDataToUI()
  core_vehicleBridge.executeAction(getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', true)

  if restoreInProgress then
    restoreCurrent = restoreCurrent + 1
    core_jobsystem.create(function(job)
      job.sleep(RESTORE_SETTLE_TIME)
      processNextRestorePart()
    end)
  elseif saveForLaterEnabled and shoppingSessionActive then
    persistCartDraftToFile()
  end
end

local originComputerId
local function startShoppingActual(_originComputerId)
  local vehicles = career_modules_inventory.getVehicles()
  shoppingCart = {partsIn = {}, partsOut = {}, total = 0, partsInList = {}, partsOutList = {}, slotList = {}}
  partsNiceName = {}
  shoppingSessionActive = true
  slotToPartIdMap = deepcopy(career_modules_partInventory.getSlotToPartIdMap())
  -- Older car-meet purchases could be saved without a partInventory entry.
  -- Keep those vehicles modifiable instead of indexing a nil slot map.
  slotToPartIdMap[currentVehicle] = slotToPartIdMap[currentVehicle] or {}

  initialVehicle = deepcopy(vehicles[currentVehicle])
  initialVehicle.partList = flattenPartsTree(initialVehicle.config.partsTree)

  -- Fill partsNiceName with initial vehicle parts
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)
  for _, partName in pairs(initialVehicle.partList) do
    if partName and partName ~= "" then
      local partInfo = availableParts[partName]
      if partInfo then
        partsNiceName[partName] = partInfo.description
      end
    end
  end

  previewVehicle = deepcopy(initialVehicle)

  partShopId = 0
  generatePartShop()
  originComputerId = _originComputerId

  M.setupTether()

  openUIState()

  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(getCurrentVehicleObj():getPosition() - getPlayerVehicle(0):getPosition())
  end

  core_vehicleBridge.executeAction(getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', true)
  extensions.hook("onPartShoppingStarted")
  maybeStartCartRestore()
end

local function setupTether()
    -- calculate the size of the vehicle to use for tethering
  local oobb = getCurrentVehicleObj():getSpawnWorldOOBB()
  local vehCenter = oobb:getCenter()
  local vehRadius = (oobb:getPoint(0) - oobb:getPoint(6)):length()
  -- calculate computer position
  local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("computer",originComputerId))

  local distBetweenVehicleAndComputer = (computerPos-vehCenter):length()
  -- this smoothly scales the radius from 100% for 4m or less distance to 150% for 12m or more radius
  local radiusMultipler = ((clamp(distBetweenVehicleAndComputer,4,12)-4)/16 + 1)
  -- these radii are tuned for the wcusa garage!
  tether = career_modules_tether.startCapsuleTetherBetweenStatics(computerPos, 10*radiusMultipler, vehCenter, vehRadius + (9*radiusMultipler), M.cancelShopping)
end

local function startShopping(inventoryId, _originComputerId)
  currentVehicle = inventoryId or career_modules_inventory.getCurrentVehicle()
  if not currentVehicle then
    currentVehicle = career_modules_inventory.getInventoryIdsInClosestGarage(true)
  end
  if not currentVehicle then return end

  local numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[currentVehicle].partConditions)
  if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_valueCalculator.getBrokenPartsThreshold() then
    career_modules_insurance_insurance.startRepair(currentVehicle, nil, function() startShoppingActual(_originComputerId) end)
  else
    startShoppingActual(_originComputerId)
  end
end

local function getDefaultPartName(jbeamData, slotName)
  if not jbeamData or not jbeamData.slots2 then return end
  for _, slot in ipairs(jbeamData.slots2) do
    if slot.name == slotName and slot.default and slot.default ~= "" then return slot.default end
  end
end

-- Some older vehicle mods have a default part whose slotType does not exactly
-- match the slot that declares it. Free roam still installs that explicit
-- default by name, while career's stricter fit check used to reject and add it
-- forever. Treat a parent's named default as authoritative, but warn once so
-- the broken JBeam remains visible to mod authors.
local function partFitsSlotOrIsDeclaredDefault(parentJbeamData, slotName, partData, partName, slotInfo)
  if not partData or not slotInfo then return false end
  if jbeamSlotSystem.partFitsSlot(partData, slotInfo) then return true end

  local defaultPartName = getDefaultPartName(parentJbeamData, slotName)
  if defaultPartName and partName == defaultPartName then
    local warningKey = tostring(parentJbeamData.partName) .. "|" .. tostring(slotName) .. "|" .. tostring(partName)
    if not warnedDeclaredDefaultMismatches[warningKey] then
      warnedDeclaredDefaultMismatches[warningKey] = true
      log("W", "partShopping",
        string.format(
          "Accepting declared default '%s' for slot '%s' despite a slotType mismatch (parent '%s')",
          tostring(partName), tostring(slotName), tostring(parentJbeamData.partName)
        )
      )
    end
    return true
  end

  return false
end

local function getFittingPartFromInventory(parentPart, slotName, currentVehicleData)
  for partId, inventoryPart in pairs(career_modules_partInventory.getInventory()) do
    local partSlotOfThisPartInShoppingCart = getPartSlotFromPartIdInShoppingCart(partId) -- for checking if the part is already in the shopping cart

    local partDescription = jbeamIO.getPart(currentVehicleData.ioCtx, inventoryPart.name)
    if not inventoryPart.enginePackageId and inventoryPart.location == 0 and inventoryPart.vehicleModel == parentPart.vehicleModel and (not partSlotOfThisPartInShoppingCart) and jbeamSlotSystem.partFitsSlot(partDescription, parentPart.description.slotInfoUi[slotName]) then
      local shopPart = deepcopy(inventoryPart)
      shopPart.containingSlot = parentPart.containingSlot .. slotName .. "/"
      shopPart.partPath = shopPart.containingSlot .. inventoryPart.name
      shopPart.slot = slotName
      shopPart.vehicleModel = parentPart.vehicleModel
      shopPart.partId = partId
      shopPart.partShopId = partShopId
      partShopId = partShopId + 1
      shopPart.finalValue = 0
      return shopPart
    end
  end
end

local function getNeededAdditionalParts(parts, inventoryId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehicleObj = getObjectByID(vehId)
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)

  -- Make a map from slot to its part for the parts which were already in the vehicle and the parts which we want to add
  local combinedSlotToPartMap = {}
  for containingSlot, partId in pairs(slotToPartIdMap[inventoryId]) do
    combinedSlotToPartMap[containingSlot] = deepcopy(career_modules_partInventory.getInventory()[partId])
  end
  for _, part in pairs(parts) do
    combinedSlotToPartMap[part.containingSlot] = deepcopy(part)
  end

  for path, part in pairs(combinedSlotToPartMap) do
    local jbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, part.name)
    part.slotType = jbeamData.slotType
  end

  -- add the default part if the slot is empty and they have a default part
  local addedParts = false
  local resultParts = deepcopy(parts)
  for _, part in pairs(parts) do
    if part.description.slotInfoUi then
      local parentJbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, part.name)
      for slotName, slotInfo in pairs(part.description.slotInfoUi) do
        local path = part.containingSlot .. slotName .. "/"
        local installedPart = combinedSlotToPartMap[path]
        if not installedPart or not partFitsSlotOrIsDeclaredDefault(parentJbeamData, slotName, installedPart, installedPart.name, slotInfo) then -- found an empty slot
          -- look for a fitting part from the inventory
          local fittingPart = getFittingPartFromInventory(part, slotName, currentVehicleData)

          if not fittingPart then
            local partNameToGenerate = getDefaultPartName(parentJbeamData, slotName)
            if partNameToGenerate then -- found a default part name
              fittingPart = generatePart(partNameToGenerate, currentVehicleData, availableParts, path, slotName, vehicleObj)
            end
          end

          if fittingPart then
            resultParts[fittingPart.containingSlot] = fittingPart
            addedParts = true
            if not slotInfo.coreSlot then
              fittingPart.sourcePart = true
            end
          end
        end
      end
    end
  end
  return resultParts, addedParts
end

-- TODO refactor for new parts system
local function findIncompatiblePartsInShoppingCartRec(partName, availableParts, node, vehicleParts, ioCtx)
  if not node or not node.children then return end

  local parentJbeamData = jbeamIO.getPart(ioCtx, partName)

  -- Traverse through the vehicle parts tree
  for slotName, childNode in pairs(node.children) do
    local subPartName = childNode.chosenPartName

    if vehicleParts[childNode.path] then
      local description = availableParts[partName]
      local slotInfo = description and description.slotInfoUi and description.slotInfoUi[slotName]
      local subPart = jbeamIO.getPart(ioCtx, subPartName)

      if (shoppingCart.partsIn[childNode.path] and shoppingCart.partsIn[childNode.path].emptyPlaceholder) then
        -- This is an intentionally empty slot, so all child parts are incompatible
        vehicleParts[childNode.path] = nil
      elseif subPartName and subPartName ~= "" and
             partFitsSlotOrIsDeclaredDefault(parentJbeamData, slotName, subPart, subPartName, slotInfo) then
        vehicleParts[childNode.path] = nil
        findIncompatiblePartsInShoppingCartRec(subPartName, availableParts, childNode, vehicleParts, ioCtx)
      end
    end
  end
end

-- TODO this returns "main"
local function findIncompatiblePartsInShoppingCart()
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)

  local mainPartName = jbeamIO.getMainPartName(currentVehicleData.ioCtx)
  local vehiclePartsTree = deepcopy(previewVehicle.config.partsTree)
  local vehicleParts = flattenPartsTree(vehiclePartsTree)

  for path, part in pairs(vehicleParts) do
    -- Remove the root part
    if (path == "/") then
      vehicleParts[path] = nil
    end
  end

  -- Remove all parts of the "vehicleParts" list that are in the vehicle correctly. Then only the incorrect ones will remain
  findIncompatiblePartsInShoppingCartRec(mainPartName, availableParts, vehiclePartsTree, vehicleParts, currentVehicleData.ioCtx)
  return vehicleParts
end

-- fill the preview vehicle with the initial parts
local function fillWithInitialParts(containingSlot, currentVehicleData)
  local node = getNodeFromSlotPath(previewVehicle.config.partsTree, containingSlot)
  local initialVehicleNode = getNodeFromSlotPath(initialVehicle.config.partsTree, containingSlot)
  if initialVehicleNode and initialVehicleNode.chosenPartName and initialVehicleNode.chosenPartName ~= "" then
    node.chosenPartName = initialVehicleNode.chosenPartName
    previewVehicle.partConditions[initialVehicleNode.partPath] = initialVehicle.partConditions[initialVehicleNode.partPath]
    for _, slot in ipairs(initialVehicleNode.children or {}) do
      fillWithInitialParts(slot.path, currentVehicleData)
    end
  else
    node.chosenPartName = ""
  end
end

local function fillEmptySlotsWithInitialParts(initialNode, previewNode)
  if not initialNode or not previewNode then return end

  -- Fill current node if empty
  if previewNode.chosenPartName == "" and initialNode.chosenPartName and initialNode.chosenPartName ~= "" and not previewNode.emptyPlaceholder then
    previewNode.chosenPartName = initialNode.chosenPartName
    previewVehicle.partConditions[initialNode.partPath] = initialVehicle.partConditions[initialNode.partPath]
  end

  -- Recursively process children
  if initialNode.children then
    for slotName, initialChildNode in pairs(initialNode.children) do
      -- Create preview child node if it doesn't exist
      if not previewNode.children then previewNode.children = {} end
      if not previewNode.children[slotName] then
        previewNode.children[slotName] = {
          chosenPartName = "",
          children = {},
          suitablePartNames = {initialChildNode.chosenPartName},
          unsuitablePartNames = {},
          decisionMethod = "user"
        }
      end

      -- Recurse into child nodes
      fillEmptySlotsWithInitialParts(
        initialChildNode,
        previewNode.children[slotName]
      )
    end
  end
end

local function updateInstalledParts(addedParts, removedParts)
  if not shoppingSessionActive then return end

  if addedParts then
    local firstPart = next(addedParts)
    if firstPart and not addedParts[firstPart].emptyPlaceholder then
      local werePartsAdded
      local previousSignature
      local passCount = 0
      repeat
        passCount = passCount + 1
        addedParts, werePartsAdded = getNeededAdditionalParts(addedParts, currentVehicle)
        for path, part in pairs(addedParts) do
          local node = getNodeFromSlotPath(previewVehicle.config.partsTree, part.containingSlot)
          if node then
            node.chosenPartName = part.name
          else
            -- Get the parent path by removing everything after the second-to-last "/"
            local parentPath = part.containingSlot:match("(.+)/[^/]+/$") or "/"
            local parentNode = getNodeFromSlotPath(previewVehicle.config.partsTree, parentPath)
            if parentNode then
              parentNode.children = parentNode.children or {}
              parentNode.children[part.slot] = {chosenPartName = part.name, path = parentNode.path .. part.slot .. "/", children = {}, suitablePartNames = {part.name}, unsuitablePartNames = {}, decisionMethod = "user"}
            end
          end
        end

        if werePartsAdded then
          local signatureParts = {}
          for path, part in pairs(addedParts) do
            signatureParts[#signatureParts + 1] =
              tostring(path) .. "\0" .. tostring(part and part.name) .. "\0" .. tostring(part and part.partId)
          end
          table.sort(signatureParts)
          local signature = table.concat(signatureParts, "\1")

          if signature == previousSignature then
            log("E", "partShopping",
              "Stopped additional-part resolution because the part set made no forward progress")
            werePartsAdded = false
          elseif passCount >= MAX_ADDITIONAL_PART_PASSES then
            log("E", "partShopping",
              string.format("Stopped additional-part resolution after %d passes", MAX_ADDITIONAL_PART_PASSES))
            werePartsAdded = false
          end
          previousSignature = signature
        end
      until not werePartsAdded
    end
    tableMerge(shoppingCart.partsIn, addedParts)
  end

  if removedParts then
    local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())

    for containingSlot, part in pairs(removedParts) do
      -- If there was another part in the slot before, put the initial part back in, otherwise leave the slot empty
      local initialPartName = initialVehicle.partList[containingSlot]
      local initialPart = jbeamIO.getPart(currentVehicleData.ioCtx, initialPartName)

      if initialPartName and initialPartName ~= "" and jbeamSlotSystem.partFitsSlot(initialPart, previewVehicleSlotData[containingSlot]) then
        fillWithInitialParts(containingSlot, currentVehicleData)
      else
        local node = getNodeFromSlotPath(previewVehicle.config.partsTree, containingSlot)
        if node then node.chosenPartName = "" end
      end
      shoppingCart.partsIn[containingSlot] = nil
    end
  end

  -- Add new parts to preview vehicle data
  for _, part in pairs(shoppingCart.partsIn) do
    local node = getNodeFromSlotPath(previewVehicle.config.partsTree, part.containingSlot)
    if node then
      if part.emptyPlaceholder then
        -- this means the slot is intentionally empty
        node.chosenPartName = ""
        node.emptyPlaceholder = true
      else
        node.chosenPartName = part.name
      end
    end
  end

  -- Find and remove parts from the shopping cart that are not compatible anymore after the installed parts have changed
  local incompatibleParts = findIncompatiblePartsInShoppingCart()
  for slot, partName in pairs(incompatibleParts) do
    shoppingCart.partsIn[slot] = nil
    local node = getNodeFromSlotPath(previewVehicle.config.partsTree, slot)
    if node then node.chosenPartName = "" end
  end

  -- Fill the empty slots with initial vehicle parts using both methods
  fillEmptySlotsWithInitialParts(initialVehicle.config.partsTree, previewVehicle.config.partsTree)

  -- Add the partCondition of the new parts to the previewVehicle
  for _, part in pairs(shoppingCart.partsIn) do
    previewVehicle.partConditions[part.partPath] = part.partCondition
  end

  local additionalVehicleData = {spawnWithEngineRunning = false}
  core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, getCurrentVehicleObj():getID())

  local spawnOptions = {}
  spawnOptions.config = previewVehicle.config
  spawnOptions.keepOtherVehRotation = true

  core_vehicles.replaceVehicle(previewVehicle.model, spawnOptions, getCurrentVehicleObj())
  core_vehicleBridge.executeAction(getCurrentVehicleObj(), 'initPartConditions', previewVehicle.partConditions, nil, nil, nil, career_modules_painting.getPrimerColor())

  -- Doing the callback immediately will result in wrong values for some parts, so we do it one frame later
  core_vehicleBridge.requestValue(getCurrentVehicleObj(),
  function()
    queueCallbackInVehicle(getCurrentVehicleObj(), "career_modules_partShopping.updatePreviewVehicle", "partCondition.getConditions()")
  end
  , 'ping')
end

removePart = function(part)
  if not shoppingSessionActive then return end
  local removedParts = {}
  removedParts[part.containingSlot] = part
  updateInstalledParts(nil, removedParts)
end

installPart = function(part)
  if not shoppingSessionActive then return end

  -- only make this a sourcePart if it is not in a core slot or if the initial vehicle has a part in that slot
  -- this way we make sure that a core slot can never be empty
  if not previewVehicleSlotData[part.containingSlot].coreSlot or initialVehicle.partList[part.containingSlot] and initialVehicle.partList[part.containingSlot] ~= "" then
    part.sourcePart = true
  end
  local newParts = {}
  newParts[part.containingSlot] = part
  updateInstalledParts(newParts)

  extensions.hook("onPartShoppingPartInstalled", {part = part})
end

local function installPartByPartShopId(partShopId)
  if restoreInProgress then
    return
  end
  for _, part in ipairs(partsInShop) do
    if part.partShopId == partShopId then
      installPart(part)
      return
    end
  end
end

local function removePartBySlot(slot)
  if restoreInProgress then
    return
  end
  for _, part in pairs(shoppingCart.partsIn) do
    if part.containingSlot == slot then
      removePart(part)
      return
    end
  end
end

local closeMenuAfterSaving
local function closeMenu()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
  if tether then
    tether.remove = true
    tether = nil
  end
end

local function endShopping(_closeMenuAfterSaving)
  closeMenuAfterSaving = career_career.isAutosaveEnabled() and _closeMenuAfterSaving
  shoppingSessionActive = false
  if not closeMenuAfterSaving then
    closeMenu()
  end
end

local function restoreVehicleAndEndShopping()
  if initialVehicle and currentVehicle then
    local vehicles = career_modules_inventory.getVehicles()
    if vehicles then
      local restored = deepcopy(initialVehicle)
      restored.partList = nil
      vehicles[currentVehicle] = restored
    end
  end

  extensions.hook("onPartShoppingCancelled")
  career_modules_inventory.spawnVehicle(currentVehicle, 2)
  endShopping()
end

-- Explicit Cancel: revert the vehicle and drop any saved cart draft.
local function discardShopping()
  if not shoppingSessionActive then
    return
  end

  abortCartRestore()
  clearCartDraftForVehicle(currentVehicle)
  saveForLaterEnabled = false
  restoreVehicleAndEndShopping()
end

-- Persist the current cart, revert the vehicle, and leave.
local function saveCartForLater()
  if not shoppingSessionActive then
    return
  end
  if not shoppingCart or not shoppingCart.partsInList or tableSize(shoppingCart.partsInList) == 0 then
    return
  end

  abortCartRestore()
  saveForLaterEnabled = true
  persistCartDraftToFile()
  saveForLaterEnabled = false
  restoreVehicleAndEndShopping()
end

-- Used by tether / UI unmount. Keep an in-progress cart rather than wiping it.
local function cancelShopping()
  if not shoppingSessionActive then
    return
  end
  if shoppingCart and shoppingCart.partsInList and tableSize(shoppingCart.partsInList) > 0 then
    saveCartForLater()
    return
  end

  abortCartRestore()
  saveForLaterEnabled = false
  restoreVehicleAndEndShopping()
end

local function requestExit()
  guihooks.trigger("partShoppingRequestExit")
end

local function onSaveFinished()
  if closeMenuAfterSaving then
    closeMenu()
    closeMenuAfterSaving = nil
  end
end

local function updateInventory()
  local vehicle = career_modules_inventory.getVehicles()[currentVehicle]
  for slot, part in pairs(shoppingCart.partsOut) do
    part.location = 0
    vehicle.changedSlots[slot] = true
  end

  vehicle.partList = nil

  for slot, part in pairs(shoppingCart.partsIn) do
    if part.emptyPlaceholder then
      goto continue
    end
    local partId = part.partId
    local partComesFromInventory = part.partId ~= nil
    part.location = currentVehicle
    part.partShopId = nil
    part.sourcePart = nil
    part.finalValue = nil
    part.partId = nil
    part.disabled = nil
    part.disabledReason = nil
    vehicle.changedSlots[slot] = true
    if partComesFromInventory then
      career_modules_partInventory.getInventory()[partId] = part
    else
      career_modules_partInventory.addPartToInventory(part)
    end
    ::continue::
  end
end

local function getInstalledPartsHookData()
  local installedParts = {}
  for _, part in pairs(shoppingCart.partsIn or {}) do
    if not part.emptyPlaceholder then
      table.insert(installedParts, {
        name = part.name,
        partPath = part.partPath,
        containingSlot = part.containingSlot,
        fromInventory = part.partId ~= nil,
      })
    end
  end
  return installedParts
end

local function getBuyingLabel()
  local parts = {}
  for i=1,tableSize(shoppingCart.partsInList) - 1 do
    local part = shoppingCart.partsInList[i]
    table.insert(parts, part.description.description)
  end
  local part = shoppingCart.partsInList[tableSize(shoppingCart.partsInList)]
  table.insert(parts, part.description.description)
  return {
    txt = "ui.career.partShopping.boughtNewParts",
    context = {parts = table.concat(parts, ", ")},
  }
end

local function applyShopping()
  if not career_modules_payment.canPay({money = {amount = shoppingCart.total}}) then return end

  abortCartRestore()
  clearCartDraftForVehicle(currentVehicle)
  saveForLaterEnabled = false

  local vehicles = career_modules_inventory.getVehicles()
  local installedParts = getInstalledPartsHookData()
  vehicles[currentVehicle] = previewVehicle
  career_modules_vehiclePerformance.invalidateCertification(currentVehicle)
  updateInventory()
  -- Tire wear state must be attached to newly installed parts before the
  -- transaction autosave and vehicle respawn. Inventory-sourced parts retain
  -- their own state; newly purchased parts are initialized as fresh.
  extensions.hook("onPartShoppingPartsInstalled", currentVehicle, installedParts)
  endShopping()
  local buyingLabel = getBuyingLabel()
  career_modules_playerAttributes.addAttributes({money=-shoppingCart.total}, {tags={"partsBought", "buying"},label=buyingLabel})
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent({currentVehicle}, {force = true})
  else
    career_modules_inventory.updatePartConditions(nil, currentVehicle)
  end

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  core_vehicleBridge.executeAction(getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', false)
  extensions.hook("onPartShoppingTransactionComplete")
  gameplay_achievement.unlockAchievement("VEHICLE_MODIFIED")
end

local function isShoppingSessionActive()
  return shoppingSessionActive
end

-- Breadcrumb title resolver for the part-shopping category route. Receives the
-- "category" route param and returns a localized label.
local function getCategoryBreadcrumbTitle(category)
  if category == "cargo" then
    return _tr("ui.career.partShopping.cargoParts")
  end
  -- "everything" (and any unknown value) maps to the All Parts category.
  return _tr("ui.career.partShopping.allParts")
end

-- Breadcrumb title resolver for the part-shopping slot route. Receives the
-- "slotPath" route param and returns the slot's nice name when known.
local function getSlotBreadcrumbTitle(slotPath)
  if type(slotPath) ~= "string" or slotPath == "" then return nil end
  -- The slot name is the last non-empty segment of the path.
  local slotName
  for segment in string.gmatch(slotPath, "[^/]+") do
    slotName = segment
  end
  return slotName and slotsNiceName[slotName] or nil
end

local function getPartsInShop()
  return partsInShop
end

local function getShoppingCart()
  return shoppingCart
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["partShop"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "partShop",
      routeTarget = "career.computer.partShopping",
      label = _tr("ui.career.shared.pathPartCustomization"),
      callback = function() startShopping(inventoryId, menuData.computerFacility.id) end,
      order = 1
    }
    -- vehicle broken
    if vehicleData.needsRepair then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.needsRepair
    end
    -- tutorial active
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
    end

    -- generic gameplay reason
    local reason = career_modules_permissions.getStatusForTag({"partBuying", "vehicleModification"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

M.startShopping = startShopping
M.installPart = installPart
M.installPartByPartShopId = installPartByPartShopId
M.removePartBySlot = removePartBySlot
M.updatePreviewVehicle = updatePreviewVehicle
M.cancelShopping = cancelShopping
M.discardShopping = discardShopping
M.saveCartForLater = saveCartForLater
M.requestExit = requestExit
M.applyShopping = applyShopping
M.sendShoppingDataToUI = sendShoppingDataToUI
M.onRouteEnter = onRouteEnter
M.onRouteMount = onRouteMount

M.getPartsInShop = getPartsInShop
M.getShoppingCart = getShoppingCart
M.isShoppingSessionActive = isShoppingSessionActive
M.getCategoryBreadcrumbTitle = getCategoryBreadcrumbTitle
M.getSlotBreadcrumbTitle = getSlotBreadcrumbTitle

M.setupTether = setupTether
M.onComputerAddFunctions = onComputerAddFunctions
M.onSaveFinished = onSaveFinished
M.setSaveForLater = setSaveForLater
M.getSaveForLater = getSaveForLater

local function onVehicleRemoved(inventoryId)
  clearCartDraftForVehicle(inventoryId)
end

M.onVehicleRemoved = onVehicleRemoved

return M
