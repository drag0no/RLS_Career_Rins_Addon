local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/guide.json"
local settingsRoot = "settings/RLS/"
local globalGuideFile = settingsRoot .. "guideGlobal.json"

local SPLASH_DELAY_S = 0.5
local VETERAN_PHONE_TUTORIAL_DELAY_S = 3.0
local PHONE_OPEN_DELAY_S = 0.35
local PHONE_TUTORIAL_EVENT_DELAY_S = 0.65

local guideShown = false
local phoneTutorialComplete = false
local globalPhoneTutorialComplete = false
local splashVisible = false
local skipDemoDirtIntro = false
local phoneTutorialStartScheduled = false
local returnToOverhaulManagerPending = false
local startPhoneTutorialIfNeeded

-- Stock fade tutorials (cargo / delivery help, etc.) already use
-- career/tutorialData.json, but that is per-save only and easy to lose.
-- Mirror the phone-tutorial pattern: remember them in RLS guide + global
-- settings so they stay suppressed after the first time.
local STOCK_INTRO_TIP_IDS = {
  "delivery/cargoScreen",
  "delivery/parcelDeliveryHelp",
  "delivery/vehicleDeliveryHelp",
  "delivery/trailerDeliveryHelp",
  "delivery/materialsDeliveryHelp",
  "delivery/loanerHelp",
  "delivery/cargoDelivered",
  "delivery/postDeliveryTaxi",
  "delivery/intro",
}

local STOCK_INTRO_TIP_HOOKS = {
  onEnterCargoOverviewScreen = "delivery/cargoScreen",
}

local seenStockIntroTips = {}
local globalSeenStockIntroTips = {}

local INTRO_SKIP_FIELDS = {
  demo_dirt = "skipDemoDirtIntro",
}

local function copySeenTipMap(source)
  local out = {}
  if type(source) ~= "table" then
    return out
  end
  for _, id in ipairs(STOCK_INTRO_TIP_IDS) do
    if source[id] == true then
      out[id] = true
    end
  end
  -- Also accept any extra string keys already stored.
  for key, value in pairs(source) do
    if type(key) == "string" and value == true then
      out[key] = true
    end
  end
  return out
end

local function mergeSeenTipMaps(...)
  local out = {}
  for i = 1, select("#", ...) do
    local map = select(i, ...)
    if type(map) == "table" then
      for key, value in pairs(map) do
        if value == true then
          out[key] = true
        end
      end
    end
  end
  return out
end

local function isTrackedStockIntroTip(id)
  if type(id) ~= "string" or id == "" then
    return false
  end
  for _, tipId in ipairs(STOCK_INTRO_TIP_IDS) do
    if tipId == id then
      return true
    end
  end
  return false
end

local function ensureGlobalSettingsDir()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot, true)
  end
end

local function loadGlobalGuideData()
  ensureGlobalSettingsDir()
  local data = jsonReadFile(globalGuideFile) or {}
  globalPhoneTutorialComplete = data.phoneTutorialComplete == true
  globalSeenStockIntroTips = copySeenTipMap(data.seenStockIntroTips)
end

local function writeGlobalGuideFile(data)
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    if career_saveSystem.jsonWriteFileSafe(globalGuideFile, data, true) then
      return true
    end
  end
  if jsonWriteFileSafe and jsonWriteFileSafe(globalGuideFile, data, true) then
    return true
  end
  if jsonWriteFile and jsonWriteFile(globalGuideFile, data, true) then
    return true
  end
  return false
end

local function saveGlobalGuideData()
  ensureGlobalSettingsDir()
  local data = {
    phoneTutorialComplete = globalPhoneTutorialComplete == true,
    seenStockIntroTips = copySeenTipMap(globalSeenStockIntroTips),
  }
  if writeGlobalGuideFile(data) then
    return true
  end
  log("E", "guide", "failed to write global guide data: " .. tostring(globalGuideFile))
  return false
end

local function promotePerSaveTutorialToGlobal()
  if globalPhoneTutorialComplete then
    return
  end
  globalPhoneTutorialComplete = true
  saveGlobalGuideData()
end

local function applyStockIntroTipsToTutorialPopups()
  local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
  if not (tutorialPopups and tutorialPopups.setTutorialFlag) then
    return
  end
  local merged = mergeSeenTipMaps(seenStockIntroTips, globalSeenStockIntroTips)
  for id, seen in pairs(merged) do
    if seen == true then
      tutorialPopups.setTutorialFlag(id, true)
    end
  end
end

local function syncSeenTipsFromStockTutorialFlags()
  local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
  if not (tutorialPopups and tutorialPopups.getTutorialFlag) then
    return false
  end
  local changed = false
  for _, id in ipairs(STOCK_INTRO_TIP_IDS) do
    if tutorialPopups.getTutorialFlag(id) and not seenStockIntroTips[id] then
      seenStockIntroTips[id] = true
      changed = true
    end
    if tutorialPopups.getTutorialFlag(id) and not globalSeenStockIntroTips[id] then
      globalSeenStockIntroTips[id] = true
      changed = true
    end
  end
  return changed
end

local function isPhoneTutorialCompleteGlobally()
  return globalPhoneTutorialComplete == true
end

local function isForcePhoneTutorial()
  local settings = rawget(_G, "overhaul_settings")
  if not settings or not settings.getSetting then
    return false
  end
  return settings.getSetting("forcePhoneTutorial") == true
end

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function readSkipFlagFromData(data, eventKey)
  if type(data) ~= "table" or not eventKey or eventKey == "" then
    return false
  end
  local field = INTRO_SKIP_FIELDS[eventKey]
  if field and data[field] == true then
    return true
  end
  if type(data.demoIntroSkip) == "table" and data.demoIntroSkip[eventKey] == true then
    return true
  end
  return false
end

local function loadGuideData()
  if not career_career.isActive() then
    return
  end

  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return
  end

  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  guideShown = data.guideShown or false
  phoneTutorialComplete = data.phoneTutorialComplete or false
  skipDemoDirtIntro = readSkipFlagFromData(data, "demo_dirt")
  seenStockIntroTips = copySeenTipMap(data.seenStockIntroTips)
  if phoneTutorialComplete then
    promotePerSaveTutorialToGlobal()
  end
end

local function saveGuideData(currentSavePath)
  if not currentSavePath then
    local _, path = career_saveSystem.getCurrentProfile()
    currentSavePath = path
  end

  if not currentSavePath then
    return false
  end

  local existing = jsonReadFile(currentSavePath .. saveFile)
  if skipDemoDirtIntro ~= true and readSkipFlagFromData(existing, "demo_dirt") then
    skipDemoDirtIntro = true
  end

  ensureSaveDir(currentSavePath)

  local data = {
    guideShown = guideShown,
    phoneTutorialComplete = phoneTutorialComplete == true,
    skipDemoDirtIntro = skipDemoDirtIntro == true,
    seenStockIntroTips = copySeenTipMap(mergeSeenTipMaps(seenStockIntroTips, globalSeenStockIntroTips)),
  }

  if career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true) then
    return true
  end
  log("E", "guide", "failed to write guide save: " .. tostring(currentSavePath .. saveFile))
  return false
end

local function markStockIntroTipSeen(id)
  if not isTrackedStockIntroTip(id) then
    return false
  end
  local changed = false
  if not seenStockIntroTips[id] then
    seenStockIntroTips[id] = true
    changed = true
  end
  if not globalSeenStockIntroTips[id] then
    globalSeenStockIntroTips[id] = true
    changed = true
  end

  local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
  if tutorialPopups and tutorialPopups.setTutorialFlag then
    tutorialPopups.setTutorialFlag(id, true)
  end

  if not changed then
    return false
  end

  saveGlobalGuideData()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if currentSavePath then
    saveGuideData(currentSavePath)
  end
  return true
end

local function refreshStockIntroTipSuppression()
  loadGlobalGuideData()
  loadGuideData()
  if syncSeenTipsFromStockTutorialFlags() then
    saveGlobalGuideData()
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    if currentSavePath then
      saveGuideData(currentSavePath)
    end
  end
  applyStockIntroTipsToTutorialPopups()
end

local function checkGuideShown()
  return guideShown
end

local function markGuideShown()
  guideShown = true
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if currentSavePath then
    saveGuideData(currentSavePath)
  end
end

local function shouldSkipDemoIntro(eventKey)
  if not eventKey or eventKey == "" then
    return false
  end
  if not INTRO_SKIP_FIELDS[eventKey] then
    return false
  end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return false
  end
  return readSkipFlagFromData(jsonReadFile(currentSavePath .. saveFile), eventKey)
end

-- Writes guide.json into one autosave folder; returns true on success.
local function writeSkipToSlot(basePath, field)
  local dirPath = basePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local data = jsonReadFile(basePath .. saveFile) or {}
  data[field] = true
  if data.guideShown == nil then
    data.guideShown = guideShown == true
  end
  data.demoIntroSkip = nil
  return career_saveSystem.jsonWriteFileSafe(basePath .. saveFile, data, true) == true
end

-- BeamNG rotates autosave slots and loads the newest on restart, so the skip
-- flag must land in every autosave of the current save, not just the live one.
local function markDemoIntroSkipped(eventKey)
  if not eventKey or eventKey == "" then
    return false
  end
  local field = INTRO_SKIP_FIELDS[eventKey]
  if not field then
    return false
  end

  if eventKey == "demo_dirt" then
    skipDemoDirtIntro = true
  end

  local wroteAny = false
  local slotName = career_saveSystem.getCurrentProfile()
  if slotName and career_saveSystem.getSaveRootDirectory and career_saveSystem.getAllAutosaves then
    local saveRoot = career_saveSystem.getSaveRootDirectory()
    local autosaves = career_saveSystem.getAllAutosaves(slotName) or {}
    for _, info in ipairs(autosaves) do
      if info and info.name then
        if writeSkipToSlot(saveRoot .. slotName .. "/" .. info.name, field) then
          wroteAny = true
        end
      end
    end
  end

  if not wroteAny then
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    if currentSavePath then
      wroteAny = writeSkipToSlot(currentSavePath, field)
    end
  end

  if wroteAny then
    print("[guide] marked demo intro skipped (all autosaves): " .. tostring(eventKey))
    log("I", "guide", "marked demo intro skipped: " .. tostring(eventKey))
    return true
  end
  print("[guide] failed to mark demo intro skipped: " .. tostring(eventKey))
  log("E", "guide", "failed to mark demo intro skipped: " .. tostring(eventKey))
  return false
end

local function showSplash()
  if splashVisible then return end

  splashVisible = true
  guihooks.trigger('GuideShowSplash')
end

local function onSaveCurrentProfile(currentSavePath)
  if not currentSavePath then
    return
  end
  local success, err = pcall(function()
    saveGuideData(currentSavePath)
  end)
  if not success then
    log("E", "guide", "onSaveCurrentProfile failed: " .. tostring(err))
  end
end

M.onCareerActivated = function()
  phoneTutorialStartScheduled = false
  refreshStockIntroTipSuppression()
end

M.onCareerModulesActivated = function()
  phoneTutorialStartScheduled = false
  refreshStockIntroTipSuppression()
end

M.showSplashIfNeeded = function()
  refreshStockIntroTipSuppression()

  if isPhoneTutorialCompleteGlobally() and not isForcePhoneTutorial() then
    if not checkGuideShown() then
      core_jobsystem.create(function(job)
        job.sleep(SPLASH_DELAY_S)
        showSplash()
      end)
    end
    return
  end

  if checkGuideShown() then
    startPhoneTutorialIfNeeded({ initialDelay = VETERAN_PHONE_TUTORIAL_DELAY_S })
    return
  end

  core_jobsystem.create(function(job)
    job.sleep(SPLASH_DELAY_S)
    showSplash()
  end)
end

local function returnToOverhaulManagerIfNeeded()
  if not returnToOverhaulManagerPending then
    return
  end
  returnToOverhaulManagerPending = false
  if gameplay_phone and gameplay_phone.markClosed then
    gameplay_phone.markClosed()
  end
  extensions.ui_router.navigate('menu.overhaulManager')
end

M.markPhoneTutorialComplete = function()
  phoneTutorialStartScheduled = false
  if isForcePhoneTutorial() then
    returnToOverhaulManagerIfNeeded()
    return true
  end
  phoneTutorialComplete = true
  globalPhoneTutorialComplete = true
  saveGlobalGuideData()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  local saved
  if currentSavePath then
    saved = saveGuideData(currentSavePath)
  else
    saved = saveGlobalGuideData()
  end
  returnToOverhaulManagerIfNeeded()
  return saved
end

M.isPhoneTutorialComplete = function()
  loadGlobalGuideData()
  return isPhoneTutorialCompleteGlobally()
end

local function formatControlName(control, deviceName)
  if not control or control == "" then
    return "Not bound"
  end

  control = tostring(control)

  if deviceName and deviceName:find("mouse") then
    local btnNum = tonumber(control:match("button(%d+)"))
    if btnNum then
      if btnNum == 0 then return "Mouse Left"
      elseif btnNum == 1 then return "Mouse Right"
      elseif btnNum == 2 then return "Mouse Middle"
      else return "Mouse Button " .. (btnNum + 1) end
    end
    return "Mouse " .. control
  end

  local symbolMap = {
    backslash = "\\", slash = "/", comma = ",", period = ".",
    semicolon = ";", apostrophe = "'", grave = "`", minus = "-",
    equals = "=", leftbracket = "[", rightbracket = "]"
  }
  if symbolMap[control] then
    return symbolMap[control]
  end
  if control:len() == 1 then
    return control:upper()
  elseif control:match("^f%d+$") then
    return control:upper()
  elseif control == "space" then
    return "Space"
  elseif control == "enter" then
    return "Enter"
  elseif control == "tab" then
    return "Tab"
  elseif control:find("arrow") then
    local direction = control:gsub("arrow", "")
    if direction == "left" then return "Arrow Left"
    elseif direction == "right" then return "Arrow Right"
    elseif direction == "up" then return "Arrow Up"
    elseif direction == "down" then return "Arrow Down"
    else return "Arrow " .. direction:gsub("^%l", string.upper) end
  end

  return control:gsub("^%l", string.upper):gsub("_", " ")
end

local function getPhoneBinding()
  if not core_input_bindings then
    return {binding = "Not bound"}
  end

  if core_input_bindings.notifyUI then
    pcall(function() core_input_bindings.notifyUI("guide refresh") end)
  end

  if core_input_bindings.bindings then
    for _, device in ipairs(core_input_bindings.bindings) do
      if device.contents and device.contents.bindings and type(device.contents.bindings) == "table" then
        for _, b in ipairs(device.contents.bindings) do
          if b.action == "openPhone" and b.control and b.control ~= "" then
            return {binding = formatControlName(b.control, device.devname)}
          end
        end
      end
    end
  end

  return {binding = "Not bound"}
end

startPhoneTutorialIfNeeded = function(opts)
  opts = opts or {}
  loadGlobalGuideData()
  loadGuideData()

  local forceTutorial = isForcePhoneTutorial() or opts.force == true
  if isPhoneTutorialCompleteGlobally() and not forceTutorial then
    return
  end
  if phoneTutorialStartScheduled then
    return
  end

  phoneTutorialStartScheduled = true
  local initialDelay = tonumber(opts.initialDelay) or PHONE_OPEN_DELAY_S

  core_jobsystem.create(function(job)
    job.sleep(initialDelay)
    if isPhoneTutorialCompleteGlobally() and not (isForcePhoneTutorial() or forceTutorial) then
      phoneTutorialStartScheduled = false
      return
    end
    if gameplay_phone and gameplay_phone.openForTutorial then
      gameplay_phone.openForTutorial()
    else
      extensions.ui_router.navigate('phone-main')
    end
    job.sleep(PHONE_TUTORIAL_EVENT_DELAY_S)
    if isPhoneTutorialCompleteGlobally() and not (isForcePhoneTutorial() or forceTutorial) then
      phoneTutorialStartScheduled = false
      return
    end
    local bindingInfo = getPhoneBinding()
    guihooks.trigger('PhoneTutorialStart', {
      binding = bindingInfo and bindingInfo.binding or 'Not bound',
    })
  end)
end

M.forceStartPhoneTutorial = function()
  local em = rawget(_G, "overhaul_extensionManager")
  if not (em and em.isDevKeyValid and em.isDevKeyValid()) then
    return false
  end
  phoneTutorialStartScheduled = false
  returnToOverhaulManagerPending = true
  startPhoneTutorialIfNeeded({
    initialDelay = PHONE_OPEN_DELAY_S,
    force = true,
  })
  return true
end

M.onContinue = function()
  if splashVisible then
    splashVisible = false
    markGuideShown()
    guihooks.trigger('GuideHideSplash')
    startPhoneTutorialIfNeeded()
  end
end

local function setPhoneBinding(controlString, deviceName)
  if not controlString or controlString == "" then
    return {success = false, binding = "Not bound"}
  end

  local activeActions = core_input_actions and core_input_actions.getActiveActions()
  if not activeActions or not activeActions.openPhone then
    if overhaul_extensionManager and overhaul_extensionManager.ensureInputActionsRegistered then
      overhaul_extensionManager.ensureInputActionsRegistered()
      activeActions = core_input_actions and core_input_actions.getActiveActions()
    end
  end
  if not activeActions or not activeActions.openPhone then
    log("E", "guide", "Cannot bind phone because the openPhone input action is unavailable")
    return {success = false, binding = "Not bound"}
  end

  if not deviceName then deviceName = "keyboard0" end

  if not core_input_bindings or not core_input_bindings.bindings then
    log("E", "guide", "core_input_bindings not available")
    return {success = false, binding = "Not bound"}
  end

  local targetDevice = nil
  for _, device in ipairs(core_input_bindings.bindings) do
    if device.devname == deviceName then
      targetDevice = device
      break
    end
  end

  if not targetDevice or not targetDevice.contents then
    log("E", "guide", "Could not find device: " .. tostring(deviceName))
    return {success = false, binding = "Not bound"}
  end

  local deviceContents = targetDevice.contents
  if not deviceContents.bindings or type(deviceContents.bindings) ~= "table" then
    log("E", "guide", "Device has no bindings table")
    return {success = false, binding = "Not bound"}
  end

  local bindings = deviceContents.bindings
  for i = #bindings, 1, -1 do
    if bindings[i].action == "openPhone" then
      table.remove(bindings, i)
    end
  end

  local newBinding = {
    action = "openPhone",
    control = controlString,
    player = 0,
  }
  local bindingTemplate = core_input_bindings.bindingTemplate
  if type(bindingTemplate) == "table" then
    for k, v in pairs(bindingTemplate) do
      if newBinding[k] == nil then
        newBinding[k] = v
      end
    end
  end
  table.insert(bindings, newBinding)

  local ok = pcall(function()
    core_input_bindings.saveBindingsToDisk(deviceContents)
  end)

  if not ok then
    log("E", "guide", "Failed to save phone binding to disk")
  end

  local bindingName = formatControlName(controlString, deviceName)
  return {success = ok, binding = bindingName}
end

M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding
M.onRecordingActionDown = function() end
M.shouldSkipDemoIntro = shouldSkipDemoIntro
M.markDemoIntroSkipped = markDemoIntroSkipped
M.markStockIntroTipSeen = markStockIntroTipSeen

-- After stock shows/closes a tip, mirror into RLS guide + global so new saves skip it.
M.onIntroPopupCareerClosed = function(id)
  markStockIntroTipSeen(id)
end

for hookName, tipId in pairs(STOCK_INTRO_TIP_HOOKS) do
  M[hookName] = function()
    -- Wait a tick so stock tutorialPopups can open + set its own flag first.
    -- Marking immediately can race and suppress the first-ever show.
    if not core_jobsystem or not core_jobsystem.create then
      markStockIntroTipSeen(tipId)
      return
    end
    core_jobsystem.create(function(job)
      job.sleep(0.15)
      local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
      if tutorialPopups and tutorialPopups.getTutorialFlag and tutorialPopups.getTutorialFlag(tipId) then
        markStockIntroTipSeen(tipId)
      end
    end)
  end
end

M.onSaveCurrentProfile = onSaveCurrentProfile

return M
