local M = {}

M.dependencies = {"career_saveSystem"}

local logTag = "career.saveMigration"
local manifestRelativePath = "/career/rls_career/legacyMigration.json"
local reportRelativePath = "/career/rls_career/legacyMigrationReport.json"
local activeMigrationPlan

local function addIssue(report, severity, code, title, detail, extra)
  local issue = {
    severity = severity,
    code = code,
    title = title,
    detail = detail,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      issue[key] = value
    end
  end
  table.insert(report.issues, issue)
  if severity == "blocker" then
    report.blockerCount = report.blockerCount + 1
  elseif severity == "action" then
    report.actionCount = report.actionCount + 1
  else
    report.warningCount = report.warningCount + 1
  end
end

local function splitSavePath(savePath)
  if type(savePath) ~= "string" then
    return nil
  end
  return savePath:match("([^/\\]+)$")
end

local function getSavePath(profile, specificSaveFolder)
  if type(profile) ~= "string" or profile == "" then
    return nil
  end

  local saveRoot = career_saveSystem.getSaveRootDirectory()
  if specificSaveFolder and specificSaveFolder ~= "" then
    local candidate = saveRoot .. profile .. "/" .. specificSaveFolder
    if FS:directoryExists(candidate) then
      return candidate
    end
    return nil
  end

  local newest = career_saveSystem.getNewestSave(saveRoot .. profile)
  if newest and newest ~= "" then
    return newest
  end
  return nil
end

local function modelExists(model)
  if type(model) ~= "string" or model == "" then
    return false
  end
  local vehicleDir = "/vehicles/" .. model .. "/"
  if not FS:directoryExists(vehicleDir) then
    return false
  end
  -- core_vehicles.getModel() builds the complete enabled vehicle/config cache
  -- on first use. With large mod sets that can stall or exhaust the profile
  -- screen, while migration only needs to know whether this model's content is
  -- currently mounted.
  local jbeamFiles = FS:findFiles(vehicleDir, "*.jbeam", -1, false, false)
  return type(jbeamFiles) == "table" and #jbeamFiles > 0
end

-- path.getPathLevelMain() only ever returns the legacy '<level>/main.level.json'
-- entry point. Every modern level (west_coast_usa included) ships a '<level>/main/'
-- scene tree instead and has no such file, so testing that path alone reports every
-- current map as missing. This mirrors core/levels.lua's own entry-point resolution.
local function levelExists(level)
  if type(level) ~= "string" or level == "" then
    return false, nil
  end

  local levelDir = "/levels/" .. level .. "/"
  if not FS:directoryExists(levelDir) then
    return false, levelDir
  end

  local sceneTreeDir = levelDir .. "main/"
  if FS:directoryExists(sceneTreeDir) then
    return true, sceneTreeDir
  end

  local legacyMain = path.getPathLevelMain(level)
  if legacyMain and FS:fileExists(legacyMain) then
    return true, legacyMain
  end

  local missionFiles = FS:findFiles(levelDir, "*.mis", 1, true, false) or {}
  if #missionFiles > 0 then
    return true, missionFiles[1]
  end

  return false, levelDir
end

-- A career vehicle respawns from the parts data held inside the save itself
-- (config.partsTree, plus vars/paints), not from the .pc it was originally bought
-- from. config.partConfigFilename is only a provenance breadcrumb: shop configs get
-- renamed, and mod configs disappear when the mod is unmounted, while the saved car
-- still rebuilds perfectly. Only fall back to the file when the save carries no
-- parts data of its own.
local function configExists(config)
  if type(config) ~= "table" then
    return false, nil
  end

  local filename = config.partConfigFilename
  if type(filename) ~= "string" or filename == "" then
    filename = nil
  elseif filename:sub(1, 1) ~= "/" then
    filename = "/" .. filename
  end

  local partsTree = config.partsTree
  if type(partsTree) == "table" and next(partsTree) ~= nil then
    return true, filename
  end

  local parts = config.parts
  if type(parts) == "table" and next(parts) ~= nil then
    return true, filename
  end

  if filename then
    return FS:fileExists(filename), filename
  end
  return false, filename
end

local function getGarageFacilityIndex()
  local result = {}
  local facilityFiles = FS:findFiles("/levels/", "*.facilities.json", -1, false, false) or {}
  table.sort(facilityFiles)
  for _, facilityFile in ipairs(facilityFiles) do
    local data = jsonReadFile(facilityFile)
    if type(data) == "table" and type(data.garages) == "table" then
      local level = facilityFile:match("^/levels/([^/]+)/")
      for _, garage in ipairs(data.garages) do
        if type(garage) == "table" and type(garage.id) == "string" and not result[garage.id] then
          result[garage.id] = {
            id = garage.id,
            name = garage.name or garage.id,
            defaultPrice = math.max(0, tonumber(garage.defaultPrice) or 0),
            capacity = math.max(0, tonumber(garage.capacity) or 0),
            starterGarage = garage.starterGarage == true,
            level = level,
          }
        end
      end
    end
  end
  return result
end

local function getSavedHousingMarketIndex(savePath)
  local economy = jsonReadFile(savePath .. "/career/rls_career/globalEconomy.json")
  local index = type(economy) == "table"
    and type(economy.housingMarket) == "table"
    and tonumber(economy.housingMarket.index)
    or nil
  return index and math.max(0, index) or 1
end

local function getSavedMortgages(savePath)
  local data = jsonReadFile(savePath .. "/career/rls_career/mortgages.json")
  return type(data) == "table" and type(data.mortgages) == "table" and data.mortgages or {}
end

local function getUniqueMigrationName(profile)
  local saveRoot = career_saveSystem.getSaveRootDirectory()
  local base = tostring(profile) .. " (Migrated 0.39)"
  local candidate = base
  local suffix = 2
  while FS:directoryExists(saveRoot .. candidate) do
    candidate = base .. " " .. suffix
    suffix = suffix + 1
  end
  return candidate
end

local function getLegacySavePreflight(profile, specificSaveFolder)
  local targetVersion = career_saveSystem.getSaveSystemVersion()
  local minimumVersion = career_saveSystem.getBackwardsCompVersion()
  local savePath = getSavePath(profile, specificSaveFolder)
  local report = {
    schemaVersion = 1,
    profile = profile,
    saveFolder = specificSaveFolder,
    savePath = savePath,
    sourceVersion = nil,
    targetVersion = targetVersion,
    requiresMigration = false,
    preparedMigration = false,
    canMigrate = true,
    blockerCount = 0,
    actionCount = 0,
    warningCount = 0,
    vehicleCount = 0,
    compatibleVehicleCount = 0,
    incompatibleVehicleCount = 0,
    vehicles = {},
    garageCount = 0,
    availableGarageCount = 0,
    unavailableGarageCount = 0,
    garages = {},
    issues = {},
    defaultTargetProfile = getUniqueMigrationName(profile),
  }

  if not savePath then
    report.canMigrate = false
    addIssue(report, "blocker", "save.missing", "Save data was not found", "No readable save folder could be selected.")
    return report
  end

  report.saveFolder = splitSavePath(savePath)
  local info = jsonReadFile(savePath .. "/info.json")
  if type(info) ~= "table" then
    report.canMigrate = false
    addIssue(report, "blocker", "save.infoMissing", "Save metadata is unreadable", "The selected save has no readable info.json.")
    return report
  end

  report.sourceVersion = tonumber(info.version)
  report.corrupted = info.corrupted == true
  report.requiresMigration = report.sourceVersion ~= nil and report.sourceVersion < targetVersion

  local prepared = jsonReadFile(savePath .. manifestRelativePath)
  if type(prepared) == "table" and prepared.targetVersion == targetVersion then
    report.preparedMigration = true
    report.defaultTargetProfile = profile
  end

  if report.corrupted then
    report.canMigrate = false
    addIssue(report, "blocker", "save.corrupted", "Save is marked corrupted", "Choose an earlier healthy autosave before migrating.")
  end

  if not report.sourceVersion then
    report.canMigrate = false
    addIssue(report, "blocker", "save.versionMissing", "Save version is missing", "The migration path cannot be selected safely.")
  elseif report.sourceVersion < minimumVersion then
    report.canMigrate = false
    addIssue(
      report,
      "blocker",
      "save.unsupported",
      "Save version is too old",
      string.format("Version %d is older than the supported migration floor (%d).", report.sourceVersion, minimumVersion)
    )
  elseif report.sourceVersion > targetVersion then
    report.canMigrate = false
    addIssue(
      report,
      "blocker",
      "save.newer",
      "Save was created by a newer Career version",
      string.format("This build supports version %d, but the save is version %d.", targetVersion, report.sourceVersion)
    )
  end

  local general = jsonReadFile(savePath .. "/career/general.json")
  report.level = type(general) == "table" and general.level or nil
  if not report.level then
    report.canMigrate = false
    addIssue(report, "blocker", "map.unknown", "Saved map is unknown", "career/general.json does not contain a level.")
  else
    local levelAvailable, levelPath = levelExists(report.level)
    report.levelPath = levelPath
    if not levelAvailable then
      report.canMigrate = false
      addIssue(
        report,
        "blocker",
        "map.missing",
        "Required map is missing",
        string.format("The save requires '%s', but that level is not currently mounted.", tostring(report.level)),
        {contentId = report.level}
      )
    end
  end

  local inventory = jsonReadFile(savePath .. "/career/inventory.json")
  if type(inventory) ~= "table" then
    report.canMigrate = false
    addIssue(report, "blocker", "inventory.missing", "Vehicle inventory is unreadable", "career/inventory.json is missing or invalid.")
  end

  local vehicleFiles = FS:findFiles(savePath .. "/career/vehicles/", "*.json", 0, false, false) or {}
  table.sort(vehicleFiles)
  for _, vehicleFile in ipairs(vehicleFiles) do
    local vehicleData = jsonReadFile(vehicleFile)
    if type(vehicleData) ~= "table" then
      report.canMigrate = false
      addIssue(
        report,
        "blocker",
        "vehicle.unreadable",
        "Vehicle record cannot be migrated safely",
        splitSavePath(vehicleFile) or tostring(vehicleFile)
      )
    else
      local availableModel = modelExists(vehicleData.model)
      local availableConfig, configPath = configExists(vehicleData.config)
      local available = availableModel and availableConfig
      local vehicle = {
        id = tonumber(vehicleData.id) or vehicleData.id,
        name = vehicleData.niceName or vehicleData.model or "Unknown vehicle",
        model = vehicleData.model,
        configPath = configPath,
        savedValue = tonumber(vehicleData.configBaseValue) or 0,
        owned = vehicleData.owned ~= false,
        loanType = vehicleData.loanType,
        location = vehicleData.location,
        niceLocation = vehicleData.niceLocation,
        available = available,
        modelAvailable = availableModel,
        configAvailable = availableConfig,
        recommendedAction = available and "preserve" or "quarantine",
        issues = {},
      }

      report.vehicleCount = report.vehicleCount + 1
      if available then
        report.compatibleVehicleCount = report.compatibleVehicleCount + 1
      else
        report.incompatibleVehicleCount = report.incompatibleVehicleCount + 1
        if not availableModel then
          table.insert(vehicle.issues, "Vehicle model is missing or disabled")
        end
        if not availableConfig then
          table.insert(vehicle.issues, "Saved configuration is missing")
        end
        addIssue(
          report,
          "action",
          "vehicle.contentMissing",
          string.format("%s cannot currently be spawned", tostring(vehicle.name)),
          table.concat(vehicle.issues, ". ") .. ". It is highlighted for review before migration.",
          {vehicleId = vehicle.id, contentId = vehicle.model}
        )
      end
      table.insert(report.vehicles, vehicle)
    end
  end

  local purchasedGarageData = jsonReadFile(savePath .. "/career/rls_career/purchasedGarages.json")
  if type(purchasedGarageData) == "table" and type(purchasedGarageData.garages) == "table" then
    local facilityIndex = getGarageFacilityIndex()
    local housingMarketIndex = getSavedHousingMarketIndex(savePath)
    local mortgages = getSavedMortgages(savePath)
    for garageId, owned in pairs(purchasedGarageData.garages) do
      if owned then
        local facility = facilityIndex[tostring(garageId)]
        local mortgage = mortgages[tostring(garageId)]
        local mortgageBalance = type(mortgage) == "table"
          and math.max(0, tonumber(mortgage.remainingBalance or mortgage.principal) or 0)
          or 0
        local marketValue = facility
          and math.floor(facility.defaultPrice * housingMarketIndex + 0.5)
          or 0
        local grossSaleValue = math.floor(marketValue * 0.75 + 0.5)
        local garage = {
          id = tostring(garageId),
          name = facility and facility.name or tostring(garageId),
          level = facility and facility.level or nil,
          capacity = facility and facility.capacity or 0,
          available = facility ~= nil,
          marketValue = marketValue,
          grossSaleValue = grossSaleValue,
          mortgageBalance = mortgageBalance,
          savedValue = math.max(0, grossSaleValue - mortgageBalance),
          vehicleCount = 0,
          issues = {},
        }

        for _, vehicle in ipairs(report.vehicles) do
          if tostring(vehicle.location or "") == garage.id then
            garage.vehicleCount = garage.vehicleCount + 1
          end
        end

        report.garageCount = report.garageCount + 1
        if garage.available then
          report.availableGarageCount = report.availableGarageCount + 1
        else
          report.unavailableGarageCount = report.unavailableGarageCount + 1
          table.insert(garage.issues, "Garage content is missing or disabled")
          addIssue(
            report,
            "action",
            "garage.contentMissing",
            string.format("%s cannot currently be found", tostring(garage.name)),
            "Its ownership record is highlighted for review and can be safely removed during migration.",
            {garageId = garage.id, contentId = garage.id}
          )
        end
        table.insert(report.garages, garage)
      end
    end
    table.sort(report.garages, function(a, b)
      return tostring(a.name):lower() < tostring(b.name):lower()
    end)
  end

  if report.requiresMigration then
    addIssue(
      report,
      "warning",
      "save.versionUpgrade",
      "Legacy Career data requires migration",
      string.format("A separate copy will be upgraded from version %d to version %d.", report.sourceVersion, targetVersion)
    )
  end

  return report
end

local function normalizeVehicleIds(values)
  local result = {}
  local seen = {}
  if type(values) ~= "table" then
    return result
  end
  for _, value in ipairs(values) do
    local id = tonumber(value)
    if id and not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end
  table.sort(result)
  return result
end

local function normalizeGarageIds(values)
  local result = {}
  local seen = {}
  if type(values) ~= "table" then
    return result
  end
  for _, value in ipairs(values) do
    local id = tostring(value or "")
    if id ~= "" and not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end
  table.sort(result)
  return result
end

local function idsToLookup(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    local id = tonumber(value)
    if id then
      result[id] = true
    end
  end
  return result
end

local function stringIdsToLookup(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    local id = tostring(value or "")
    if id ~= "" then
      result[id] = true
    end
  end
  return result
end

local function addMigrationCompensation(targetSavePath, amount, vehicleCount, partCount, garageCount)
  amount = math.max(0, tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end

  local attributesPath = targetSavePath .. "/career/playerAttributes.json"
  local attributes = jsonReadFile(attributesPath)
  if type(attributes) ~= "table" then
    return false, "The copied save has no readable player attributes for the migration payout."
  end

  attributes.money = type(attributes.money) == "table" and attributes.money or {value = 0, gains = {}, losses = {}}
  attributes.money.gains = type(attributes.money.gains) == "table" and attributes.money.gains or {}
  attributes.money.losses = type(attributes.money.losses) == "table" and attributes.money.losses or {}
  attributes.money.value = (tonumber(attributes.money.value) or 0) + amount
  attributes.money.gains.all = (tonumber(attributes.money.gains.all) or 0) + amount
  attributes.money.gains.migration = (tonumber(attributes.money.gains.migration) or 0) + amount
  attributes.money.gains.selling = (tonumber(attributes.money.gains.selling) or 0) + amount

  if not career_saveSystem.jsonWriteFileSafe(attributesPath, attributes, true) then
    return false, "The migration payout could not be written to the copied save."
  end

  local attributeLogPath = targetSavePath .. "/career/attributeLog.json"
  local attributeLog = jsonReadFile(attributeLogPath)
  if type(attributeLog) ~= "table" then
    attributeLog = {}
  end
  table.insert(attributeLog, {
    attributeChange = {money = amount},
    reason = {
      label = string.format(
        "Legacy save migration: sold %d vehicle%s, %d loose part%s, and %d garage%s",
        vehicleCount,
        vehicleCount == 1 and "" or "s",
        partCount,
        partCount == 1 and "" or "s",
        garageCount or 0,
        garageCount == 1 and "" or "s"
      ),
      tags = {migration = true, selling = true},
    },
    time = os.time(),
  })
  if not career_saveSystem.jsonWriteFileSafe(attributeLogPath, attributeLog, true) then
    return false, "The migration payout history could not be written to the copied save."
  end
  return true
end

local function preprocessVehicleCashOut(targetSavePath, cashOutVehicleIds, sellParts)
  local vehicleValue = 0
  local appliedVehicleIds = {}

  for _, inventoryId in ipairs(cashOutVehicleIds) do
    local vehiclePath = targetSavePath .. "/career/vehicles/" .. inventoryId .. ".json"
    local vehicle = jsonReadFile(vehiclePath)
    -- Autosave copies can diverge; missing records in this folder are a no-op.
    if type(vehicle) == "table" then
      if vehicle.owned ~= false then
        vehicleValue = vehicleValue + math.max(0, tonumber(vehicle.configBaseValue) or 0)
      end
      table.insert(appliedVehicleIds, inventoryId)
    end
  end

  local appliedLookup = idsToLookup(appliedVehicleIds)

  local inventoryPath = targetSavePath .. "/career/inventory.json"
  local inventory = jsonReadFile(inventoryPath)
  if type(inventory) ~= "table" then
    if #appliedVehicleIds == 0 then
      return {
        appliedVehicleIds = appliedVehicleIds,
        vehicleValue = 0,
        partValue = 0,
        soldPartCount = 0,
        totalValue = 0,
      }
    end
    return nil, "The copied vehicle inventory could not be read."
  end
  for inventoryId in pairs(appliedLookup) do
    if tonumber(inventory.currentVehicle) == inventoryId then inventory.currentVehicle = nil end
    if tonumber(inventory.lastVehicle) == inventoryId then inventory.lastVehicle = nil end
    if tonumber(inventory.favoriteVehicle) == inventoryId then inventory.favoriteVehicle = nil end
    if type(inventory.spawnedPlayerVehicles) == "table" then
      inventory.spawnedPlayerVehicles[inventoryId] = nil
      inventory.spawnedPlayerVehicles[tostring(inventoryId)] = nil
    end
  end
  if not career_saveSystem.jsonWriteFileSafe(inventoryPath, inventory, true) then
    return nil, "The copied vehicle inventory could not be updated."
  end

  local partValue = 0
  local soldPartCount = 0
  local partInventoryPath = targetSavePath .. "/career/partInventory.json"
  local partInventoryJson = jsonReadFile(partInventoryPath)
  if type(partInventoryJson) == "table" and type(partInventoryJson[1]) == "string" then
    local ok, partInventory = pcall(deserialize, partInventoryJson[1])
    if not ok or type(partInventory) ~= "table" then
      return nil, "The copied part inventory could not be decoded."
    end
    local changed = false
    for partId, part in pairs(partInventory) do
      local location = type(part) == "table" and tonumber(part.location) or nil
      if sellParts or (location and appliedLookup[location]) then
        if sellParts and location == 0 then
          partValue = partValue + math.max(0, tonumber(part.value) or 0)
          soldPartCount = soldPartCount + 1
        end
        partInventory[partId] = nil
        changed = true
      end
    end
    if changed and not career_saveSystem.jsonWriteFileSafe(partInventoryPath, {serialize(partInventory)}, true) then
      return nil, "The copied part inventory could not be updated."
    end
  elseif sellParts and #appliedVehicleIds > 0 then
    return nil, "The copied save has no readable part inventory."
  end

  for inventoryId in pairs(appliedLookup) do
    FS:removeFile(targetSavePath .. "/career/vehicles/" .. inventoryId .. ".json")
    FS:removeFile(targetSavePath .. "/career/vehicles/" .. inventoryId .. ".jpg")
    FS:removeFile(targetSavePath .. "/career/vehicles/damage/" .. inventoryId .. "_damageState.json")
  end

  local totalValue = vehicleValue + partValue
  local payoutOk, payoutError = addMigrationCompensation(
    targetSavePath,
    totalValue,
    #appliedVehicleIds,
    soldPartCount
  )
  if not payoutOk then
    return nil, payoutError
  end

  return {
    appliedVehicleIds = appliedVehicleIds,
    vehicleValue = vehicleValue,
    partValue = partValue,
    soldPartCount = soldPartCount,
    totalValue = totalValue,
  }
end

-- Rebuild insurance.json for the kept fleet: fresh invVehs keyed by remaining
-- vehicle files, merged with any salvageable per-vehicle rows from the old file.
-- Also bumps info.json to targetVersion so insurance load does not treat this as
-- a brand-new save and wipe the bookkeeping again.
local function preprocessInsurance(targetSavePath, cashOutVehicleIds, targetVersion)
  local insurancePath = targetSavePath .. "/career/insurance.json"
  local oldData = jsonReadFile(insurancePath)
  if type(oldData) ~= "table" then
    oldData = {}
  end

  local cashOutLookup = idsToLookup(cashOutVehicleIds)
  local oldInvVehs = type(oldData.invVehs) == "table" and oldData.invVehs or {}

  local function lookupOldInvVeh(inventoryId)
    local row = oldInvVehs[inventoryId]
    if type(row) == "table" then return row end
    row = oldInvVehs[tostring(inventoryId)]
    if type(row) == "table" then return row end
    -- Legacy saves store invVehs as an array of rows with an id field.
    for _, candidate in pairs(oldInvVehs) do
      if type(candidate) == "table" and (tonumber(candidate.id) or candidate.id) == inventoryId then
        return candidate
      end
    end
    return nil
  end

  local function ensureInvVehShape(row, inventoryId, vehicle)
    row = type(row) == "table" and row or {}
    row.id = inventoryId
    if row.insuranceId == nil then
      row.insuranceId = -1
    else
      row.insuranceId = tonumber(row.insuranceId) or -1
    end
    if type(row.name) ~= "string" or row.name == "" then
      row.name = (vehicle and vehicle.niceName) or ("Vehicle " .. tostring(inventoryId))
    end
    if type(row.initialValue) ~= "number" then
      row.initialValue = (tonumber(vehicle and vehicle.configBaseValue) or 0) / 3
    end
    if type(row.insuranceData) ~= "table" then
      row.insuranceData = {}
    end
    if type(row.insuranceData.coverageOptionsData) ~= "table" then
      row.insuranceData.coverageOptionsData = {}
    end
    if type(row.insuranceData.coverageOptionsData.currentCoverageOptions) ~= "table" then
      row.insuranceData.coverageOptionsData.currentCoverageOptions = {}
    end
    if row.insuranceData.coverageOptionsData.nextInsuranceEditTimer == nil then
      row.insuranceData.coverageOptionsData.nextInsuranceEditTimer = 0
    end
    if type(row.requiredInsuranceClass) ~= "table" then
      row.requiredInsuranceClass = {id = "standard"}
    elseif row.requiredInsuranceClass.id == nil then
      row.requiredInsuranceClass.id = "standard"
    end
    return row
  end

  local newInvVehs = {}
  local vehicleFiles = FS:findFiles(targetSavePath .. "/career/vehicles/", "*.json", 0, false, false) or {}
  for _, vehiclePath in ipairs(vehicleFiles) do
    local inventoryId = tonumber(vehiclePath:match("([%d]+)%.json$"))
    if inventoryId and not cashOutLookup[inventoryId] then
      local vehicle = jsonReadFile(vehiclePath)
      if type(vehicle) == "table" then
        newInvVehs[inventoryId] = ensureInvVehShape(lookupOldInvVeh(inventoryId), inventoryId, vehicle)
      end
    end
  end

  local newData = {
    plDriverScore = tonumber(oldData.plDriverScore) or 65,
    lastDriverScoreKmIncrease = tonumber(oldData.lastDriverScoreKmIncrease) or 0,
    totalDrivenDistance = tonumber(oldData.totalDrivenDistance) or 0,
    plInsurancesData = type(oldData.plInsurancesData) == "table" and oldData.plInsurancesData or {},
    invVehs = newInvVehs,
    plHistory = oldData.plHistory,
  }

  if not career_saveSystem.jsonWriteFileSafe(insurancePath, newData, true) then
    return false, "The copied insurance data could not be rewritten for migration."
  end

  local infoPath = targetSavePath .. "/info.json"
  local info = jsonReadFile(infoPath)
  if not targetVersion then
    return false, "The copied save version could not be updated after insurance migration."
  end
  if type(info) ~= "table" then
    return false, "The copied save info.json could not be read after insurance migration."
  end
  info.version = tonumber(targetVersion) or info.version
  if not career_saveSystem.jsonWriteFileSafe(infoPath, info, true) then
    return false, "The copied save version could not be updated after insurance migration."
  end

  return true
end

local function removeSelectedKeysFromFile(filePath, rootKey, selectedIds)
  if not FS:fileExists(filePath) then
    return true
  end
  local data = jsonReadFile(filePath)
  if type(data) ~= "table" then
    return false
  end
  local target = rootKey and data[rootKey] or data
  if type(target) ~= "table" then
    return true
  end
  for garageId in pairs(selectedIds) do
    target[garageId] = nil
  end
  return career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function preprocessGarageCashOut(targetSavePath, cashOutGarageIds, reportGarages)
  local selectedIds = stringIdsToLookup(cashOutGarageIds)
  local reportById = {}
  for _, garage in ipairs(reportGarages or {}) do
    reportById[tostring(garage.id)] = garage
  end

  local purchasedPath = targetSavePath .. "/career/rls_career/purchasedGarages.json"
  local purchasedData = jsonReadFile(purchasedPath)
  -- Divergent autosaves may lack garage tables; treat as nothing to cash out here.
  if #cashOutGarageIds > 0 and (
    type(purchasedData) ~= "table"
    or type(purchasedData.garages) ~= "table"
  ) then
    return {
      appliedGarageIds = {},
      garageValue = 0,
      grossGarageValue = 0,
      mortgageBalanceCleared = 0,
      relocatedVehicleCount = 0,
    }
  end

  local garageValue = 0
  local grossGarageValue = 0
  local mortgageBalanceCleared = 0
  local appliedGarageIds = {}
  for _, garageId in ipairs(cashOutGarageIds) do
    local garage = reportById[garageId]
    if garage and purchasedData.garages[garageId] then
      garageValue = garageValue + math.max(0, tonumber(garage.savedValue) or 0)
      grossGarageValue = grossGarageValue + math.max(0, tonumber(garage.grossSaleValue) or 0)
      mortgageBalanceCleared = mortgageBalanceCleared + math.max(0, tonumber(garage.mortgageBalance) or 0)
      purchasedData.garages[garageId] = nil
      if type(purchasedData.discovered) == "table" then
        purchasedData.discovered[garageId] = nil
      end
      table.insert(appliedGarageIds, garageId)
    end
  end

  if #appliedGarageIds > 0
    and not career_saveSystem.jsonWriteFileSafe(purchasedPath, purchasedData, true)
  then
    return nil, "The copied garage ownership data could not be updated."
  end

  local mortgagesPath = targetSavePath .. "/career/rls_career/mortgages.json"
  if not removeSelectedKeysFromFile(mortgagesPath, "mortgages", selectedIds) then
    return nil, "The copied mortgage data could not be updated."
  end
  local listingsPath = targetSavePath .. "/career/rls_career/realEstateListings.json"
  if not removeSelectedKeysFromFile(listingsPath, nil, selectedIds) then
    return nil, "The copied property listing data could not be updated."
  end
  local cooldownsPath = targetSavePath .. "/career/rls_career/negotiationCooldowns.json"
  if not removeSelectedKeysFromFile(cooldownsPath, "cooldowns", selectedIds) then
    return nil, "The copied property negotiation data could not be updated."
  end
  if not removeSelectedKeysFromFile(cooldownsPath, "frozenPrices", selectedIds) then
    return nil, "The copied frozen property pricing data could not be updated."
  end

  local negotiationPath = targetSavePath .. "/career/rls_career/realEstateNegotiationState.json"
  if FS:fileExists(negotiationPath) then
    local negotiation = jsonReadFile(negotiationPath)
    if type(negotiation) == "table" and selectedIds[tostring(negotiation.propertyId or "")] then
      if not career_saveSystem.jsonWriteFileSafe(negotiationPath, {}, true) then
        return nil, "The copied active property negotiation could not be cleared."
      end
    end
  end

  local vehicleFiles = FS:findFiles(targetSavePath .. "/career/vehicles/", "*.json", 0, false, false) or {}
  local relocatedVehicleCount = 0
  for _, vehiclePath in ipairs(vehicleFiles) do
    local vehicle = jsonReadFile(vehiclePath)
    if type(vehicle) == "table" and selectedIds[tostring(vehicle.location or "")] then
      vehicle.location = nil
      vehicle.niceLocation = nil
      if not career_saveSystem.jsonWriteFileSafe(vehiclePath, vehicle, true) then
        return nil, "A retained vehicle could not be moved out of a sold garage."
      end
      relocatedVehicleCount = relocatedVehicleCount + 1
    end
  end

  local payoutOk, payoutError = addMigrationCompensation(
    targetSavePath,
    garageValue,
    0,
    0,
    #appliedGarageIds
  )
  if not payoutOk then
    return nil, payoutError
  end

  return {
    appliedGarageIds = appliedGarageIds,
    garageValue = garageValue,
    grossGarageValue = grossGarageValue,
    mortgageBalanceCleared = mortgageBalanceCleared,
    relocatedVehicleCount = relocatedVehicleCount,
  }
end

local function prepareLegacySaveMigration(profile, specificSaveFolder, options)
  options = type(options) == "table" and options or {}
  local report = getLegacySavePreflight(profile, specificSaveFolder)
  if not report.requiresMigration then
    return {ok = false, error = "This save does not require migration.", report = report}
  end
  if not report.canMigrate or report.blockerCount > 0 then
    return {ok = false, error = "Resolve the blocking issues before migrating.", report = report}
  end

  if report.preparedMigration then
    return {
      ok = true,
      targetProfile = profile,
      targetSaveFolder = report.saveFolder,
      alreadyPrepared = true,
      report = report,
    }
  end

  local targetProfile = tostring(options.targetProfile or report.defaultTargetProfile or "")
  targetProfile = targetProfile:gsub("^%s+", ""):gsub("%s+$", "")
  if targetProfile == "" or targetProfile:find('[<>:"/\\|?*]') then
    return {ok = false, error = "Choose a valid name for the migrated copy.", report = report}
  end

  local saveRoot = career_saveSystem.getSaveRootDirectory()
  if FS:directoryExists(saveRoot .. targetProfile) then
    return {ok = false, error = "A profile with that name already exists.", report = report}
  end

  local knownIds = {}
  local unavailableIds = {}
  for _, vehicle in ipairs(report.vehicles) do
    knownIds[tonumber(vehicle.id) or vehicle.id] = true
    if not vehicle.available then
      unavailableIds[tonumber(vehicle.id) or vehicle.id] = true
    end
  end
  local knownGarageIds = {}
  for _, garage in ipairs(report.garages or {}) do
    knownGarageIds[tostring(garage.id)] = true
  end

  local vehiclePolicy = tostring(options.vehiclePolicy or "sellall")
  if vehiclePolicy ~= "sellall" and vehiclePolicy ~= "individual" and vehiclePolicy ~= "preserve" and vehiclePolicy ~= "cashout" then
    vehiclePolicy = "sellall"
  end

  local cashOutVehicleIds = {}
  if vehiclePolicy == "sellall" then
    for id in pairs(knownIds) do
      table.insert(cashOutVehicleIds, id)
    end
    table.sort(cashOutVehicleIds)
  elseif vehiclePolicy == "individual" then
    for _, id in ipairs(normalizeVehicleIds(options.cashOutVehicleIds)) do
      if knownIds[id] then
        table.insert(cashOutVehicleIds, id)
      end
    end
  elseif vehiclePolicy == "cashout" then
    -- Backwards compatibility for migration manifests created by the first UI.
    for _, id in ipairs(normalizeVehicleIds(options.cashOutVehicleIds)) do
      if unavailableIds[id] then
        table.insert(cashOutVehicleIds, id)
      end
    end
  end
  local cashOutLookup = idsToLookup(cashOutVehicleIds)
  local sellParts = vehiclePolicy == "sellall"
  local cashOutGarageIds = {}
  if vehiclePolicy == "sellall" then
    for id in pairs(knownGarageIds) do
      table.insert(cashOutGarageIds, id)
    end
    table.sort(cashOutGarageIds)
  elseif vehiclePolicy == "individual" then
    for _, id in ipairs(normalizeGarageIds(options.cashOutGarageIds)) do
      if knownGarageIds[id] then
        table.insert(cashOutGarageIds, id)
      end
    end
  end

  if not career_saveSystem.duplicateSaveSlot(profile, targetProfile) then
    return {ok = false, error = "The save copy could not be created.", report = report}
  end

  -- duplicateSaveSlot copies every autosave. Preprocess all of them so a later
  -- slot rotation / getNewestSave cannot load a stale insurance.json and wipe the fleet.
  local targetFolders = {}
  local primaryFolder = report.saveFolder
  if career_saveSystem.getAllSaveFolders then
    for _, folderInfo in ipairs(career_saveSystem.getAllSaveFolders(targetProfile) or {}) do
      if folderInfo and folderInfo.name then
        table.insert(targetFolders, folderInfo.name)
      end
    end
  end
  if #targetFolders == 0 then
    table.insert(targetFolders, primaryFolder or "autosave1")
  elseif primaryFolder then
    table.sort(targetFolders, function(a, b)
      if a == primaryFolder then return true end
      if b == primaryFolder then return false end
      return tostring(a) < tostring(b)
    end)
  end

  local targetSavePath
  local cashOutResult
  local garageCashOutResult
  for _, folderName in ipairs(targetFolders) do
    local folderSavePath = saveRoot .. targetProfile .. "/" .. folderName
    if not FS:directoryExists(folderSavePath) then
      FS:directoryRemove(saveRoot .. targetProfile)
      return {ok = false, error = "The copied save could not be prepared safely.", report = report}
    end

    local folderCashOutResult, cashOutError = preprocessVehicleCashOut(folderSavePath, cashOutVehicleIds, sellParts)
    if not folderCashOutResult then
      FS:directoryRemove(saveRoot .. targetProfile)
      return {ok = false, error = cashOutError or "The copied save could not be prepared safely.", report = report}
    end

    local folderGarageCashOutResult, garageCashOutError = preprocessGarageCashOut(
      folderSavePath,
      cashOutGarageIds,
      report.garages
    )
    if not folderGarageCashOutResult then
      FS:directoryRemove(saveRoot .. targetProfile)
      return {
        ok = false,
        error = garageCashOutError or "The copied garage data could not be prepared safely.",
        report = report,
      }
    end

    local insuranceOk, insuranceError = preprocessInsurance(
      folderSavePath,
      folderCashOutResult.appliedVehicleIds or {},
      report.targetVersion
    )
    if not insuranceOk then
      FS:directoryRemove(saveRoot .. targetProfile)
      return {
        ok = false,
        error = insuranceError or "The copied insurance data could not be prepared safely.",
        report = report,
      }
    end

    if not targetSavePath or folderName == primaryFolder then
      targetSavePath = folderSavePath
      cashOutResult = folderCashOutResult
      garageCashOutResult = folderGarageCashOutResult
    end
  end

  if not targetSavePath then
    FS:directoryRemove(saveRoot .. targetProfile)
    return {ok = false, error = "The copied save could not be prepared safely.", report = report}
  end

  local plan = {
    schemaVersion = 3,
    status = "prepared",
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    sourceProfile = profile,
    sourceSaveFolder = report.saveFolder,
    sourceVersion = report.sourceVersion,
    targetVersion = report.targetVersion,
    targetProfile = targetProfile,
    vehiclePolicy = vehiclePolicy,
    quarantinedVehicleIds = normalizeVehicleIds((function()
      local ids = {}
      for id in pairs(unavailableIds) do
        if not cashOutLookup[id] then
          table.insert(ids, id)
        end
      end
      return ids
    end)()),
    cashOutVehicleIds = cashOutVehicleIds,
    cashOutGarageIds = cashOutGarageIds,
    sellParts = sellParts,
    preprocessed = true,
    compensationAppliedToSave = true,
    vehicleCashOutValue = cashOutResult.vehicleValue,
    partCashOutValue = cashOutResult.partValue,
    soldLoosePartCount = cashOutResult.soldPartCount,
    garageCashOutValue = garageCashOutResult.garageValue,
    grossGarageCashOutValue = garageCashOutResult.grossGarageValue,
    mortgageBalanceCleared = garageCashOutResult.mortgageBalanceCleared,
    soldGarageCount = #garageCashOutResult.appliedGarageIds,
    relocatedVehicleCount = garageCashOutResult.relocatedVehicleCount,
    totalCashOutValue = cashOutResult.totalValue + garageCashOutResult.garageValue,
  }

  local manifestOk = true
  local reportOk = true
  for _, folderName in ipairs(targetFolders) do
    local folderSavePath = saveRoot .. targetProfile .. "/" .. folderName
    local migrationDir = folderSavePath .. "/career/rls_career"
    if not FS:directoryExists(migrationDir) then
      FS:directoryCreate(migrationDir, true)
    end
    manifestOk = manifestOk and career_saveSystem.jsonWriteFileSafe(folderSavePath .. manifestRelativePath, plan, true)
    reportOk = reportOk and career_saveSystem.jsonWriteFileSafe(folderSavePath .. reportRelativePath, report, true)
  end
  if not manifestOk or not reportOk then
    FS:directoryRemove(saveRoot .. targetProfile)
    return {ok = false, error = "The copied save was rolled back because its migration plan could not be written.", report = report}
  end

  log(
    "I",
    logTag,
    string.format(
      "Prepared legacy migration %s/%s -> %s/%s (v%d -> v%d)",
      profile,
      tostring(report.saveFolder),
      targetProfile,
      tostring(report.saveFolder),
      report.sourceVersion,
      report.targetVersion
    )
  )

  return {
    ok = true,
    targetProfile = targetProfile,
    targetSaveFolder = report.saveFolder,
    report = report,
  }
end

local function getPreparedMigration(profile, specificSaveFolder)
  local savePath = getSavePath(profile, specificSaveFolder)
  if not savePath then
    return nil
  end
  local plan = jsonReadFile(savePath .. manifestRelativePath)
  if type(plan) == "table" and tonumber(plan.targetVersion) == career_saveSystem.getSaveSystemVersion() then
    return plan, savePath
  end
  return nil
end

local function isPreparedMigration(profile, specificSaveFolder)
  return getPreparedMigration(profile, specificSaveFolder) ~= nil
end

local function markMigrationApplied(profile, specificSaveFolder, appliedVehicleIds)
  local plan, savePath = getPreparedMigration(profile, specificSaveFolder)
  if not plan then
    return false
  end
  plan.status = "applied"
  plan.appliedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
  plan.appliedCashOutVehicleIds = normalizeVehicleIds(appliedVehicleIds)
  activeMigrationPlan = deepcopy(plan)
  return career_saveSystem.jsonWriteFileSafe(savePath .. manifestRelativePath, plan, true)
end

local function onSaveCurrentProfile(currentSavePath)
  if type(activeMigrationPlan) ~= "table" then
    return
  end
  local migrationDir = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(migrationDir) then
    FS:directoryCreate(migrationDir, true)
  end
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. manifestRelativePath, activeMigrationPlan, true)
end

local function onBeforeSetProfile()
  activeMigrationPlan = nil
end

M.getLegacySavePreflight = getLegacySavePreflight
M.prepareLegacySaveMigration = prepareLegacySaveMigration
M.getPreparedMigration = getPreparedMigration
M.isPreparedMigration = isPreparedMigration
M.markMigrationApplied = markMigrationApplied
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onBeforeSetProfile = onBeforeSetProfile

return M
