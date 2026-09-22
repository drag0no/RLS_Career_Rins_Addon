-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local imgui = ui_imgui
local difficultyModePersist = require('ge/extensions/career/modules/difficultyModePersist')

M.dependencies = {'career_saveSystem', 'core_recoveryPrompt', 'gameplay_traffic'}

M.tutorialEnabled = false
M.startingOptions = {}

-- .39 early-loads career_career before modScript; overrideManager overlays this
-- module's functions onto the live global table. Closures still close over this
-- replacement `M`, so public fields other modules read via `career_career.*`
-- must be mirrored onto the live table.
local function publish(key, value)
  M[key] = value
  local live = rawget(_G, "career_career")
  if live ~= nil and live ~= M then
    live[key] = value
  end
end

local pendingStartingOptions = nil
local startingModesDirectory = "/lua/ge/extensions/career/startingModes/"

local debugMenuEnabled = not shipping_build

local careerModuleDirectory = '/lua/ge/extensions/career/modules/'
local saveFile = "general.json"
local levelName = "west_coast_usa"
local autosaveEnabled = true

local careerActive = false
local cachedRacingTeamFinances = nil
local careerModules = {}
local boughtStarterVehicle
local organizationInteraction = {}
local switchLevel = nil
local levelSwitchTransaction = nil
local levelSwitchSequence = 0
local lastLevelSwitchResult = {phase = "idle"}
local careerActionsBlocked = false
local activationRetryCount = 0
local activationRetrySequence = 0
local activationRetryPending = false
local lastActivationError = nil
local LEVEL_SWITCH_SAVE_TIMEOUT = 30
local MAX_ACTIVATION_RETRIES = 1
local requiredCareerModules = {
  "career_modules_inventory",
  "career_modules_payment",
  "career_modules_permissions",
  "career_modules_playerAttributes",
  "career_modules_switchMap",
}
local getActivationHealth
local completeLevelSwitch
local finalizeSuccessfulCareerActivation
-- Mid-session profile load to a different map: freeroam first (like switchLevel), then
-- activateCareer on world ready. Activating before startFreeroam races onClientEndMission
-- and overrideManager's career_modules_* gate.
local pendingProfileLoad = nil
local isNewSaveFlag = false
-- createOrLoadCareerAndStart enters "careerLoading"; activateCareer uses "careerActivate".
-- Splash used to wait on onVehicleGroupSpawned, which often never fires for the player spawn.
local careerLoadingIntroStarted = false
local careerStartInProgress = false
local pendingDifficultyMode = nil
local pendingDifficultyOverrides = nil
local pendingExperimentalMaintenanceEnabled = nil
local pendingPoliceEnabled = nil
local pendingStartingGaragePreference = nil
local pendingCareerStartMode = nil
local pendingCheatsMode = nil
local pendingSandboxEconomyProfile = nil
local pendingSandboxXpProfile = nil
local startingGaragePreference = nil

local nodegrabberActions = {"nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength", "nodegrabberAction"}

local actionWhitelist = deepcopy(nodegrabberActions)
local blockedActions = core_input_actionFilter.createActionTemplate({"vehicleTeleporting", "vehicleMenues", "physicsControls", "aiControls", "vehicleSwitching", "funStuff", "dropPlayerAtCameraNoReset"}, actionWhitelist)

local cheatblockedActions = core_input_actionFilter.createActionTemplate({"aiControls", "funStuff"})

local function resolveDifficultyMode(candidate, hardcoreFallback)
  return difficultyModePersist.resolveMode(candidate, hardcoreFallback)
end

local function normalizeDifficultyOverrides(xpMultiplier, economyMultiplier, startingCash)
  local overrides = {}

  if type(xpMultiplier) == "number" and xpMultiplier > 0 then
    overrides.xpMultiplier = xpMultiplier
  end
  if type(economyMultiplier) == "number" and economyMultiplier > 0 then
    overrides.rewardMultiplier = economyMultiplier
  end
  if type(startingCash) == "number" and startingCash >= 0 then
    overrides.startingCapital = math.floor(startingCash + 0.5)
  end

  if next(overrides) then
    return overrides
  end
  return nil
end

local function normalizeSandboxEconomyProfile(rawProfile)
  if type(rawProfile) ~= "table" then
    return nil
  end

  local umbrellas = type(rawProfile.umbrellas) == "table" and rawProfile.umbrellas or nil
  local expanded = type(rawProfile.expanded) == "table" and rawProfile.expanded or nil
  if (not umbrellas or not next(umbrellas)) and (not expanded or not next(expanded)) then
    return nil
  end

  return {
    umbrellas = umbrellas and deepcopy(umbrellas) or {},
    expanded = expanded and deepcopy(expanded) or {},
  }
end

local function normalizeSandboxXpProfile(rawProfile)
  if type(rawProfile) ~= "table" then
    return nil
  end

  local umbrellas = type(rawProfile.umbrellas) == "table" and rawProfile.umbrellas or nil
  if not umbrellas or not next(umbrellas) then
    return nil
  end

  return {
    umbrellas = deepcopy(umbrellas),
  }
end

local function normalizeStartingGaragePreference(mode, garageId)
  local normalizedMode = type(mode) == "string" and string.lower(mode) or "default"
  if normalizedMode ~= "default" and normalizedMode ~= "none" then
    normalizedMode = "default"
  end

  local normalizedGarageId = nil
  if normalizedMode == "default" and type(garageId) == "string" and garageId ~= "" then
    normalizedGarageId = garageId
  end

  return {
    mode = normalizedMode,
    garageId = normalizedGarageId
  }
end

local function getStartingGaragePreference()
  return deepcopy(startingGaragePreference or normalizeStartingGaragePreference())
end

local function setStartingGaragePreference(mode, garageId)
  startingGaragePreference = normalizeStartingGaragePreference(mode, garageId)
  pendingStartingGaragePreference = deepcopy(startingGaragePreference)
  publish("startingGaragePreference", deepcopy(startingGaragePreference))
  return deepcopy(startingGaragePreference)
end

-- newest save folder for a profile plus its save date (replaces old getAutosave)
local function getNewestSaveForProfile(profile)
  if type(profile) ~= "string" or profile == "" then return nil end
  local savePath = career_saveSystem.getNewestSave(career_saveSystem.getSaveRootDirectory() .. profile)
  if not savePath or savePath == "" then return nil end
  local info = jsonReadFile(savePath .. "/info.json")
  return savePath, info and info.date or nil
end

local function updateNodegrabberBlocking()
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
    core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', false)
    return
  end
  -- enable node grabber only in walking mode (unless cheats are enabled)
  if careerActive and (core_camera.getActiveGlobalCameraName() or not gameplay_walk.isWalking()) then
    core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
    core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', true)
    be.nodeGrabber:onMouseButton(false)
    return
  end
  core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
  core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', false)
end

local function blockInputActions(block)
  local actionsToBlock = blockedActions
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    actionsToBlock = cheatblockedActions
  end

  core_input_actionFilter.setGroup('careerBlockedActions', actionsToBlock)
  core_input_actionFilter.addAction(0, 'careerBlockedActions', block)
  careerActionsBlocked = block == true

  updateNodegrabberBlocking()
end

local function onCameraModeChanged(modeName)
  if not careerActive then return end
  updateNodegrabberBlocking()
end

local function onGlobalCameraSet(modeName)
  if not careerActive then return end
  updateNodegrabberBlocking()
end

local function onCheatsModeChanged(enabled)
  if not careerActive then return end
  blockInputActions(true)
end

local debugModules = {}
local function debugMenu()
  if not careerActive then return end
  local endCareerMode = false

  local debugSettings = settings.getValue('careerDebugSettings')
  imgui.SetNextWindowSize(imgui.ImVec2(300, 300), imgui.Cond_FirstUseEver)
  imgui.Begin("Career Debug (Save File: " .. career_saveSystem.getCurrentProfile() .. ")###Career Debug", nil, imgui.WindowFlags_MenuBar)
  imgui.BeginMenuBar()
  if imgui.BeginMenu("File") then
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    imgui.Text((string.sub(currentSavePath, string.len(career_saveSystem.getSaveRootDirectory())+2, -1)))
    imgui.Separator()
    if imgui.Selectable1("Save Career") then
      career_saveSystem.saveCurrent()
    end
    if imgui.Selectable1("Exit Career Mode") then
      endCareerMode = true
    end
    if imgui.Selectable1("Open Save Folder") then
      Engine.Platform.exploreFolder(currentSavePath:lower())
    end
    imgui.EndMenu()
  end
  if imgui.BeginMenu("Modules") then
    for _, mod in ipairs(debugModules) do
      local active = debugSettings[mod.debugName] or false
      if mod.drawDebugMenu then
        if imgui.Checkbox(mod.debugName, imgui.BoolPtr(active)) then
          debugSettings[mod.debugName] = not active
          settings.setValue('careerDebugSettings', debugSettings)
        end
      end
    end
    imgui.EndMenu()
  end

  if imgui.BeginMenu("Functions") then
    for _, mod in ipairs(careerModules) do
      if extensions[mod].drawDebugFunctions then
        imgui.Text(extensions[mod].debugName or extensions[mod].__extensionName__)
        extensions[mod].drawDebugFunctions()
        imgui.Separator()
      end
    end
    imgui.EndMenu()
  end

  imgui.EndMenuBar()
  for _, mod in ipairs(debugModules) do
    local active = debugSettings[mod.debugName] or false
    if mod.drawDebugMenu and active then
      mod.drawDebugMenu(dt)
      imgui.Separator()
    end
  end
  imgui.End()

  if endCareerMode then
    M.deactivateCareer()
    return true
  end
end

local function setupCareerActionsAndUnpause()
  blockInputActions(true)
  simTimeAuthority.pause(false)
  simTimeAuthority.set(1)
end

local function onCareerModulesActivated(alreadyInLevel)
  setupCareerActionsAndUnpause()

  if career_modules_difficultyMode then
    if pendingDifficultyMode and career_modules_difficultyMode.setMode then
      career_modules_difficultyMode.setMode(pendingDifficultyMode, false, pendingDifficultyOverrides)
      pendingDifficultyMode = nil
      pendingDifficultyOverrides = nil
    end
    if career_modules_difficultyMode.isHardcoreMode then
      publish("hardcoreMode", career_modules_difficultyMode.isHardcoreMode() == true)
    elseif career_modules_difficultyMode.getMode then
      publish("hardcoreMode", career_modules_difficultyMode.getMode() == "hardcore")
    end
  end

  -- Apply freeroam+/cheats before starting-capital logic. Cheats module also
  -- seeds on onCareerActive; publish ensures that path sees career_career.cheatsMode.
  if pendingCheatsMode and career_modules_cheats and career_modules_cheats.enableCheatsMode then
    career_modules_cheats.enableCheatsMode(true)
  end
  pendingCheatsMode = nil

  if M.pendingChallengeId then
    career_challengeModes.startChallenge(M.pendingChallengeId, true)
    publish("pendingChallengeId", nil)
  else
    if career_modules_economyAdjusterPolicy and career_modules_economyAdjusterPolicy.rebuild then
      career_modules_economyAdjusterPolicy.rebuild()
    end
    if isNewSaveFlag and career_modules_playerAttributes then
      local startingCapital = 10000
      if career_modules_difficultyMode and career_modules_difficultyMode.getStartingCapital then
        startingCapital = career_modules_difficultyMode.getStartingCapital()
      elseif M.hardcoreMode then
        startingCapital = 0
      end
      if career_modules_cheats and career_modules_cheats.isCheatsMode() then
        startingCapital = 1e12
      end

      career_modules_playerAttributes.setAttributes({
        money = startingCapital
      }, {
        label = "Starting Capital"
      })
    end
  end

  isNewSaveFlag = false
end

local skipModuleFolders = {"/tutorial/step"}

local function toggleCareerModules(active, alreadyInLevel)
  if active then
    table.clear(careerModules)
    local extensionFiles = {}
    local files = FS:findFiles(careerModuleDirectory, '*.lua', -1, true, false)
    for i = 1, tableSize(files) do
      local extensionFile = string.gsub(files[i], "/lua/ge/extensions/", "")
      extensionFile = string.gsub(extensionFile, ".lua", "")
      local skip = false
      for _, folder in ipairs(skipModuleFolders) do
        if string.find(extensionFile, folder) then
          skip = true
          break
        end
      end
      if skip then goto continue end
      table.insert(extensionFiles, extensionFile)
      table.insert(careerModules, extensions.luaPathToExtName(extensionFile))
      ::continue::
    end
    extensions.load(careerModules)
    extensions.disableSerialization(careerModules)

    -- prevent these extensions from being unloaded when switching level
    for _, extension in ipairs(extensionFiles) do
      setExtensionUnloadMode(extensions.luaPathToExtName(extension), "manual")
    end

    for _, moduleName in ipairs(careerModules) do
      local mod = extensions[moduleName]
      if mod and mod.onCareerActivated then
        mod.onCareerActivated()
      end
    end
    -- Second pass: first pass can capture nils when a sibling module's global
    -- was not visible yet (or an override load returned nil once). Rebind now
    -- that every career_modules_* extension is in _G.
    for _, moduleName in ipairs(careerModules) do
      local mod = extensions[moduleName]
      if mod and mod.onCareerActivated then
        mod.onCareerActivated()
      end
    end

    onCareerModulesActivated(alreadyInLevel)
    extensions.hook("onCareerModulesActivated", alreadyInLevel)
    debugModules = {}
    for _, moduleName in ipairs(careerModules) do
      if extensions[moduleName].debugName then
        table.insert(debugModules,extensions[moduleName])
      end
    end
    table.sort(debugModules, function(a,b) return a.debugOrder < b.debugOrder end)
  else
    for _, name in ipairs(careerModules) do
      extensions.unload(name)
    end
    table.clear(careerModules)
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not careerActive then return end
  if levelSwitchTransaction and levelSwitchTransaction.phase == "activating" and getActivationHealth and finalizeSuccessfulCareerActivation then
    local health = getActivationHealth()
    if health.ok
      and health.currentLevel == levelSwitchTransaction.destination
      and health.savedLevel == levelSwitchTransaction.destination then
      log("I", "career", "Finalizing healthy destination transaction from career update")
      finalizeSuccessfulCareerActivation()
    end
  end
  if debugMenuEnabled then
    if debugMenu() then
      return
    end
  end
  -- Racing team scheduled-race ready toasts (ui_message) must run without business computer / phone open.
  local rt = rawget(_G, "career_modules_business_racingTeam")
  if rt and rt.tickRacingTeamVehicleAssessAccumulated then
    rt.tickRacingTeamVehicleAssessAccumulated(dtSim)
  end
  if rt and rt.tickPostRaceCooldownDriverUiPushAccumulated then
    rt.tickPostRaceCooldownDriverUiPushAccumulated(dtSim)
  end
  if rt and rt.tickHomeMechanicPwDeferredRechecks then
    rt.tickHomeMechanicPwDeferredRechecks()
  end
  if rt and rt.tickScheduledRaceReadyToastsAccumulated then
    rt.tickScheduledRaceReadyToastsAccumulated(dtSim)
  end
  if rt and rt.tickRacingTeamManagerAccumulated then
    rt.tickRacingTeamManagerAccumulated(dtSim)
  end
  if rt and rt.tickRacingTeamRaceSimAccumulated then
    rt.tickRacingTeamRaceSimAccumulated(dtSim)
  end
  if not cachedRacingTeamFinances then
    local ok, mod = pcall(function()
      return require("ge/extensions/career/modules/business/racingTeamFinances")
    end)
    if ok and mod then
      cachedRacingTeamFinances = mod
    end
  end
  if cachedRacingTeamFinances and cachedRacingTeamFinances.onCareerSimStep then
    cachedRacingTeamFinances.onCareerSimStep(dtSim)
  end
end

local function onCareerActive(active)
  if not active then return end
  if M.tutorialEnabled then
    core_recoveryPrompt.setDefaultsForTutorial()
  else
    core_recoveryPrompt.setDefaultsForCareer()
  end
  guihooks.trigger('ClearTasklist')
  if ui_appContainers and ui_appContainers.showApp then
    ui_appContainers.showApp("topLeft", "tasks")
  end
  publish("onUpdate", onUpdate)
  gameplay_rawPois.clear()
  setupCareerActionsAndUnpause()
  core_gamestate.setGameState("career","career", nil)
end

local function removeNonTrafficVehicles()
  local safeIds = gameplay_traffic.getTrafficList(true)
  safeIds = arrayConcat(safeIds, gameplay_parking.getParkedCarsList(true))
  for i = be:getObjectCount()-1, 0, -1 do
    local objId = be:getObject(i):getID()
    if not tableContains(safeIds, objId) then
      be:getObject(i):delete()
    end
  end
end

local function initAfterLevelLoad(newSave)
  extensions.hook("onCareerActive", true, newSave)
end

local function getCurrentUiRouteName()
  if not (ui_router and ui_router.getState) then return nil end
  local ok, state = pcall(ui_router.getState)
  if not ok or type(state) ~= "table" or type(state.currentRoute) ~= "table" then
    return nil
  end
  local entry = state.currentRoute
  if entry.request and type(entry.request.name) == "string" then
    return entry.request.name
  end
  if entry.resolved and type(entry.resolved.screenId) == "string" then
    return entry.resolved.screenId
  end
  return nil
end

local function isProfileUiRoute(name)
  return type(name) == "string" and name:find("^career%.profiles") == 1
end

local function closeAllMenus()
  -- Loading-screen teardown can restore the previous Vue route (career.profiles)
  -- over an already-live world. Navigate to play after that restore, and again
  -- if the profile selector is still current.
  local function goPlay()
    local navOk, navResult = pcall(function()
      return extensions.ui_router.navigate("play")
    end)
    if not navOk or (type(navResult) == "table" and navResult.result == false) then
      log("W", "career", "navigate(play) failed: " .. dumps(navResult))
      guihooks.trigger("ChangeState", {state = "play", params = {}})
    end
  end
  goPlay()
  if isProfileUiRoute(getCurrentUiRouteName()) then
    log("W", "career", "profile UI still current after navigate(play); forcing ChangeState")
    guihooks.trigger("ChangeState", {state = "play", params = {}})
    goPlay()
  end
end

-- Clears createOrLoadCareerAndStart's careerLoading gate, dismisses the profile
-- selector, then starts the overhaul splash. Must not depend on onVehicleGroupSpawned.
local function finishCareerLoadingIntro(opts)
  opts = opts or {}
  local firstIntro = not careerLoadingIntroStarted
  if firstIntro and career_modules_betaWelcome and career_modules_betaWelcome.requestSplash then
    career_modules_betaWelcome.requestSplash(false)
  end
  if server and server.fadeoutLoadingScreen then
    pcall(server.fadeoutLoadingScreen)
  end
  if core_gamestate.getLoadingStatus("careerLoading") then
    core_gamestate.requestExitLoadingScreen("careerLoading")
  end
  if opts.setCamera then
    commands.setGameCamera(true)
  end
  if not firstIntro then
    return
  end
  careerLoadingIntroStarted = true
  careerStartInProgress = false
  -- Drop menus only after careerLoading is gone, otherwise the loading UI restores
  -- career.profiles on top of the world (Continue still clickable, ESC goes to pause).
  closeAllMenus()
  core_jobsystem.create(function(job)
    job.sleep(0.15)
    closeAllMenus()
    if career_modules_betaWelcome and career_modules_betaWelcome.requestSplash then
      career_modules_betaWelcome.requestSplash(false)
    end
    if career_modules_guide and career_modules_guide.showSplashIfNeeded then
      career_modules_guide.showSplashIfNeeded()
    end
  end)
end

local function getCareerPlayerIdentity()
  local playerVehicleId = be:getPlayerVehicleID(0)
  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false
  if walking and playerVehicleId and playerVehicleId >= 0 then
    return true, "walking", playerVehicleId
  end
  if playerVehicleId and playerVehicleId >= 0 and career_modules_inventory then
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehicleId)
    if inventoryId ~= nil then
      return true, "inventory", playerVehicleId, inventoryId
    end
  end
  return false, nil, playerVehicleId
end

local function ensureCareerPlayerIdentity()
  local valid = getCareerPlayerIdentity()
  if valid then return true end

  -- A map handoff suppresses freeroam's default player spawn. Inventory normally
  -- restores a car or walking mode, but an empty spawned-vehicle list can be
  -- marked complete before the unicycle exists. Force the safe walking fallback.
  spawn.preventPlayerSpawning = nil
  local gate = scenetree.findObject("Level Gate")
  local pos = gate and gate:getPosition() or nil
  local rot = gate and gate:getRotation() or nil
  gameplay_walk.setWalkingMode(true, pos, rot, true)
  return getCareerPlayerIdentity()
end

getActivationHealth = function()
  local missingModules = {}
  for _, moduleName in ipairs(requiredCareerModules) do
    local loaded = extensions.isExtensionLoaded and extensions.isExtensionLoaded(moduleName)
    if not loaded or rawget(_G, moduleName) == nil then
      table.insert(missingModules, moduleName)
    end
  end

  local gameState = core_gamestate and core_gamestate.state and core_gamestate.state.state or nil
  local playerIdentityValid, playerIdentity, playerVehicleId, inventoryId = getCareerPlayerIdentity()
  local profile, savePath = career_saveSystem.getCurrentProfile()
  local savedCareer = savePath and jsonReadFile(savePath .. "/career/" .. saveFile) or nil
  local health = {
    ok = careerActive and gameState == "career" and careerActionsBlocked and #missingModules == 0 and playerIdentityValid,
    careerActive = careerActive,
    currentLevel = getCurrentLevelIdentifier(),
    gameState = gameState,
    inputRestrictionsActive = careerActionsBlocked,
    playerIdentityValid = playerIdentityValid,
    playerIdentity = playerIdentity,
    playerVehicleId = playerVehicleId,
    playerInventoryId = inventoryId,
    missingModules = missingModules,
    profile = profile,
    savedLevel = savedCareer and savedCareer.level or nil,
    lastActivationError = lastActivationError,
  }
  return health
end

local function getLevelSwitchState()
  if levelSwitchTransaction then
    return deepcopy(levelSwitchTransaction)
  end
  return {
    phase = "idle",
    lastResult = deepcopy(lastLevelSwitchResult),
  }
end

local function closeCareerLoadingScreens()
  for _, loadingName in ipairs({"careerActivate", "careerLoading"}) do
    if core_gamestate.getLoadingStatus(loadingName) then
      core_gamestate.requestExitLoadingScreen(loadingName)
    end
  end
end

local function failLevelSwitch(reason)
  reason = tostring(reason or "Unknown map travel failure")
  local failedTransaction = levelSwitchTransaction and deepcopy(levelSwitchTransaction) or {}
  failedTransaction.phase = "failed"
  failedTransaction.lastError = reason
  lastLevelSwitchResult = failedTransaction
  levelSwitchTransaction = nil
  switchLevel = nil
  closeCareerLoadingScreens()
  simTimeAuthority.pause(false)

  if careerActive then
    setupCareerActionsAndUnpause()
    closeAllMenus()
  else
    -- A failed destination activation must remain gated instead of becoming freeroam.
    spawn.preventPlayerSpawning = true
    blockInputActions(true)
    if extensions.ui_router then
      extensions.ui_router.navigate("career.profiles")
    end
  end

  guihooks.trigger("toastrMsg", {
    type = "error",
    title = "Map travel failed",
    msg = reason,
  })
  log("E", "career", "Map travel failed: " .. reason)
end

completeLevelSwitch = function()
  if not levelSwitchTransaction then return end
  local completed = deepcopy(levelSwitchTransaction)
  completed.phase = "completed"
  completed.completedLevel = getCurrentLevelIdentifier()
  completed.lastError = nil
  lastLevelSwitchResult = completed
  levelSwitchTransaction = nil
  switchLevel = nil
  return completed
end

finalizeSuccessfulCareerActivation = function()
  local completedSwitch = completeLevelSwitch()
  -- Finalize our loading ownership before invoking third-party hooks. A hook
  -- failure must never leave a healthy destination hidden behind the loader.
  closeCareerLoadingScreens()
  finishCareerLoadingIntro({ setCamera = true })
  if completedSwitch then
    local hookOk, hookError = xpcall(function()
      extensions.hook("onCareerMapTravelCompleted", deepcopy(completedSwitch))
    end, debug.traceback)
    if not hookOk then
      log("E", "career", "Map travel completion hook failed:\n" .. tostring(hookError))
    end
  end
  return completedSwitch
end

local function startLevelSwitchSaveWatchdog(sequence)
  core_jobsystem.create(function(job)
    job.sleep(LEVEL_SWITCH_SAVE_TIMEOUT)
    if levelSwitchTransaction and levelSwitchTransaction.sequence == sequence and levelSwitchTransaction.phase == "saving" then
      failLevelSwitch("Career save did not finish within " .. tostring(LEVEL_SWITCH_SAVE_TIMEOUT) .. " seconds")
    end
  end)
end

local function activateCareer(removeVehicles, levelToLoad)
  if careerActive then return end
  local isActivationRetry = activationRetryPending
  activationRetryPending = false
  if not isActivationRetry then
    activationRetryCount = 0
    activationRetrySequence = activationRetrySequence + 1
    lastActivationError = nil
  end
  -- load career
  local profile, savePath = career_saveSystem.getCurrentProfile()
  if not profile then
    careerStartInProgress = false
    closeCareerLoadingScreens()
    return
  end
  if removeVehicles == nil then
    removeVehicles = true
  end

  local careerData = (savePath and jsonReadFile(savePath .. "/career/" .. saveFile)) or {}
  if not levelToLoad then
    levelToLoad = careerData.level or levelName
  end

  -- Already in a different level: freeroam first (same handoff as switchCareerLevel), then
  -- activate on world ready. Setting careerActive before startFreeroam lets onClientEndMission
  -- tear career down mid-flight; overrideManager then refuses career_modules_* loads.
  local currentLevel = getCurrentLevelIdentifier()
  if currentLevel and currentLevel ~= levelToLoad then
    pendingProfileLoad = {
      removeVehicles = removeVehicles,
      levelToLoad = levelToLoad,
    }
    -- careerLoading (from createOrLoad) already covers the screen; activateCareer
    -- will take careerActivate once the level is ready — same as switchCareerLevel.
    if core_groundMarkers then core_groundMarkers.setPath(nil) end
    spawn.preventPlayerSpawning = true
    freeroam_freeroam.resetSpawningOptions()
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled"
    log("I", "", string.format("Deferring career activate until level ready: %s -> %s", tostring(currentLevel), tostring(levelToLoad)))
    freeroam_freeroam.startFreeroam(path.getPathLevelMain(levelToLoad), nil, false, nil, function()
      server.fadeoutLoadingScreen()
    end)
    return
  end

  if not core_gamestate.getLoadingStatus('careerActivate') then
    core_gamestate.requestEnterLoadingScreen('careerActivate')
  end
  extensions.hook("onBeforeCareerActivate")
  if core_groundMarkers then core_groundMarkers.setPath(nil) end

  log("I", "Loading career from " .. savePath .. "/career/" .. saveFile)
  local newSave = tableIsEmpty(careerData)
  isNewSaveFlag = newSave
  local savedStartingOptions = (type(careerData.startingOptions) == "table") and careerData.startingOptions or {}
  if newSave and type(pendingStartingOptions) == "table" then
    publish("startingOptions", deepcopy(pendingStartingOptions))
  else
    publish("startingOptions", deepcopy(savedStartingOptions))
  end
  pendingStartingOptions = nil
  startingGaragePreference = newSave and pendingStartingGaragePreference or
    normalizeStartingGaragePreference(careerData.startingGarageMode, careerData.startingGarageId)
  publish("startingGaragePreference", deepcopy(startingGaragePreference))
  boughtStarterVehicle = true
  organizationInteraction = careerData.organizationInteraction or {}

  -- Publish hardcore from disk (or pending new-save choice) before modules load,
  -- so difficultyMode / garage / fines see a consistent flag on first tick.
  -- Use difficultyModePersist directly (not a later local wrapper): Lua would
  -- resolve a not-yet-declared local as a nil global and abort activation.
  if pendingDifficultyMode then
    publish("hardcoreMode", pendingDifficultyMode == "hardcore")
  else
    local savedDifficulty = difficultyModePersist.readModeFromSave(savePath)
    publish("hardcoreMode", savedDifficulty == "hardcore")
  end

  -- Disable the tutorial
  publish("tutorialEnabled", false)
  log("I", "", "Tutorial for career disabled.")

  local function finishActivateInLevel(alreadyInLevel)
    -- Must be active before toggleCareerModules: overrideManager strips career_modules_* otherwise.
    careerActive = true
    local activationOk, activationError = xpcall(function()
      toggleCareerModules(true, alreadyInLevel)
      initAfterLevelLoad(newSave)
    end, debug.traceback)

    if activationOk then
      ensureCareerPlayerIdentity()
      local health = getActivationHealth()
      if levelSwitchTransaction and getCurrentLevelIdentifier() ~= levelSwitchTransaction.destination then
        health.ok = false
        activationError = string.format(
          "Destination mismatch after activation (expected %s, got %s)",
          tostring(levelSwitchTransaction.destination), tostring(getCurrentLevelIdentifier()))
      elseif levelSwitchTransaction and health.savedLevel ~= levelSwitchTransaction.destination then
        health.ok = false
        activationError = string.format(
          "Saved career level mismatch after activation (expected %s, got %s)",
          tostring(levelSwitchTransaction.destination), tostring(health.savedLevel))
      elseif not health.ok then
        activationError = "Career activation health check failed: " .. dumps(health)
      end
      activationOk = health.ok
    end

    if not activationOk then
      lastActivationError = tostring(activationError)
      log('E', 'career', 'Career activation failed:\n' .. lastActivationError)
      publish("onUpdate", nil)
      local rollbackOk, rollbackError = xpcall(function()
        toggleCareerModules(false)
      end, debug.traceback)
      if not rollbackOk then
        log("E", "career", "Career activation rollback failed:\n" .. tostring(rollbackError))
      end
      careerActive = false
      blockInputActions(true)

      if activationRetryCount < MAX_ACTIVATION_RETRIES then
        activationRetryCount = activationRetryCount + 1
        local retrySequence = activationRetrySequence
        if levelSwitchTransaction then
          levelSwitchTransaction.phase = "activationRetry"
          levelSwitchTransaction.retryCount = activationRetryCount
          levelSwitchTransaction.lastError = lastActivationError
        end
        log("W", "career", string.format("Retrying career activation (%d/%d)", activationRetryCount, MAX_ACTIVATION_RETRIES))
        core_jobsystem.create(function(job)
          job.sleep(0.5)
          if retrySequence ~= activationRetrySequence or careerActive then return end
          activationRetryPending = true
          activateCareer(false, levelToLoad)
        end)
        return false
      end

      careerStartInProgress = false
      if levelSwitchTransaction then
        failLevelSwitch(lastActivationError)
      else
        closeCareerLoadingScreens()
        spawn.preventPlayerSpawning = true
        if extensions.ui_router then
          extensions.ui_router.navigate("career.profiles")
        end
        guihooks.trigger("toastrMsg", {
          type = "error",
          title = "Career failed to load",
          msg = "Career modules could not be activated. See the log for details.",
        })
      end
      return false
    end

    activationRetryCount = 0
    lastActivationError = nil
    finalizeSuccessfulCareerActivation()
    extensions.hook("onCareerActivationReady", deepcopy(getActivationHealth()))
    return true
  end

  if not currentLevel then
    -- Main menu / no mission: freeroam into the save's level, then activate modules in the callback.
    -- Keep careerActive false until then so a mission-end hook cannot wipe pending state.
    spawn.preventPlayerSpawning = true
    freeroam_freeroam.resetSpawningOptions()
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled" -- career_playerDriving will manage traffic setup
    freeroam_freeroam.startFreeroam(path.getPathLevelMain(levelToLoad), nil, false, nil, function()
      finishActivateInLevel(false)
      server.fadeoutLoadingScreen()
    end)
  else
    if removeVehicles then
      core_vehicles.removeAll()
    else
      removeNonTrafficVehicles()
    end
    return finishActivateInLevel(true)
  end
end

local function deactivateCareer(saveCareer)
  if not careerActive then return end
  publish("onUpdate", nil)
  careerActive = false
  careerLoadingIntroStarted = false
  pendingStartingOptions = nil
  pendingStartingGaragePreference = nil
  pendingCareerStartMode = nil
  pendingCheatsMode = nil
  pendingDifficultyMode = nil
  pendingDifficultyOverrides = nil
  pendingSandboxEconomyProfile = nil
  pendingSandboxXpProfile = nil
  publish("pendingChallengeId", nil)
  publish("pendingCareerStartMode", nil)
  publish("pendingSandboxEconomyProfile", nil)
  publish("pendingSandboxXpProfile", nil)
  publish("cheatsMode", false)
  publish("hardcoreMode", false)
  startingGaragePreference = nil
  publish("startingGaragePreference", nil)
  toggleCareerModules(false)
  blockInputActions(false)
  gameplay_rawPois.clear()
  core_recoveryPrompt.setDefaultsForFreeroam()
  extensions.hook("onCareerActive", false)
  guihooks.trigger("HideCareerTasklist")
end

local function deactivateCareerAndReloadLevel(saveCareer)
  if not careerActive then return end
  deactivateCareer(saveCareer)
  freeroam_freeroam.startFreeroam(path.getPathLevelMain(getCurrentLevelIdentifier()))
end

local function isActive()
  return careerActive
end

local function applyChallengeConfig(cfg)
  if not cfg then return false end
  if not isActive() then return false end
  if type(cfg.money) == 'number' then
    if career_modules_playerAttributes and career_modules_playerAttributes.setAttributes then
      career_modules_playerAttributes.setAttributes({money = cfg.money}, {label = "Challenge Start"})
    end
  end
  if type(cfg.loans) == 'table' and career_modules_loans and career_modules_loans.takeLoan then
    for _, l in ipairs(cfg.loans) do
      local orgId = l and l.orgId
      local amount = l and l.amount
      local payments = l and l.payments
      local rate = l and l.rate
      if orgId and type(amount) == 'number' and amount > 0 and type(payments) == 'number' and payments > 0 then
        career_modules_loans.takeLoan(orgId, amount, payments, rate)
      end
    end
  end
  return true
end

local function resolveCareerStartMode(candidate)
  if type(candidate) ~= "string" then
    return nil
  end
  local normalized = string.lower(candidate)
  if normalized == "freeroam" or normalized == "story" or normalized == "sandbox"
      or normalized == "hardcore" or normalized == "career" or normalized == "custom" then
    return normalized
  end
  return nil
end

-- Copying a legacy save can take a while, so the UI raises the loading screen before
-- it asks for the copy instead of freezing on the modal. The gamestate requests are
-- ref-counted per tag, so the careerLoading request that follows keeps the screen up
-- with no flicker in between.
local migrationLoadingScreenTag = "careerMigration"
local migrationLoadingScreenActive = false

local function beginLegacySaveMigrationLoading()
  if migrationLoadingScreenActive then return true end
  migrationLoadingScreenActive = true
  core_gamestate.requestEnterLoadingScreen(migrationLoadingScreenTag)
  return true
end

local function endLegacySaveMigrationLoading()
  if not migrationLoadingScreenActive then return false end
  migrationLoadingScreenActive = false
  core_gamestate.requestExitLoadingScreen(migrationLoadingScreenTag)
  return true
end

-- Accepts either v39 style (name, specificAutosave, startingOptionsTable)
-- or overhaul positional args (name, specificAutosave, tutorial, hardcore, ...).
-- Prefer the options table: .39's Lua bridge types the 3rd arg as Object.
local function createOrLoadCareerAndStart(name, specificAutosave, tutorial, hardcore, challengeId, cheats, startingMap, difficultyMode,
                                          experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled,
                                          xpMultiplier, economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile,
                                          sandboxXpProfile)
  local startingOptions = nil
  local legacyMigrationApproved = false
  if type(tutorial) == "table" then
    startingOptions = deepcopy(tutorial)
    legacyMigrationApproved = startingOptions.legacyMigrationApproved == true
    if startingOptions.tutorialEnabled ~= nil then
      tutorial = startingOptions.tutorialEnabled
    else
      tutorial = startingOptions.tutorial
    end
    if startingOptions.hardcoreMode ~= nil then
      hardcore = startingOptions.hardcoreMode
    else
      hardcore = startingOptions.hardcore
    end
    challengeId = startingOptions.challengeId or startingOptions.challengeSelection
    if startingOptions.cheatsMode ~= nil then
      cheats = startingOptions.cheatsMode
    else
      cheats = startingOptions.cheats
    end
    startingMap = startingOptions.startingMap
    difficultyMode = startingOptions.difficultyMode
    experimentalMaintenanceEnabled = startingOptions.experimentalMaintenanceEnabled
    startingGarageMode = startingOptions.startingGarageMode
    startingGarageId = startingOptions.startingGarageId
    if startingOptions.policeEnabled ~= nil then
      policeEnabled = startingOptions.policeEnabled
    end
    xpMultiplier = startingOptions.xpMultiplier
    economyMultiplier = startingOptions.economyMultiplier
    startingCash = startingOptions.startingCash
    -- Overhaul UI sends careerStartMode; vanilla .39 sends startMode.
    careerStartMode = startingOptions.careerStartMode or startingOptions.startMode
    sandboxEconomyProfile = startingOptions.sandboxEconomyProfile
    sandboxXpProfile = startingOptions.sandboxXpProfile
  end

  -- Freeroam+ is defined as cheats-enabled career; honor start mode even if cheatsMode was omitted.
  if resolveCareerStartMode(careerStartMode) == "freeroam" then
    cheats = true
  end

  if career_saveMigration and career_saveMigration.getLegacySavePreflight then
    local migrationReport = career_saveMigration.getLegacySavePreflight(name, specificAutosave)
    if migrationReport and migrationReport.requiresMigration then
      local prepared = career_saveMigration.isPreparedMigration
        and career_saveMigration.isPreparedMigration(name, specificAutosave)
      if not (legacyMigrationApproved and prepared) then
        -- Nothing is going to load, so drop the migration screen the UI raised for us.
        endLegacySaveMigrationLoading()
        guihooks.trigger("legacySaveMigrationRequired", migrationReport)
        log(
          "I",
          "career.migration",
          string.format(
            "Blocked direct legacy load for %s/%s until a migrated copy is prepared",
            tostring(name),
            tostring(specificAutosave)
          )
        )
        return false
      end
    end
  end

  if careerStartInProgress then
    log("W", "", "Ignoring duplicate career start; a load is already in progress")
    return false
  end

  if career_saveSystem and career_saveSystem.isSaveBusy and career_saveSystem.isSaveBusy() then
    log("W", "", "Career start blocked while a save is in progress; retry after save finishes")
    return false
  end

  core_gamestate.requestEnterLoadingScreen("careerLoading")
  -- careerLoading now holds the screen up, so hand it over without letting it close.
  endLegacySaveMigrationLoading()
  careerLoadingIntroStarted = false
  careerStartInProgress = true
  if careerActive then
    deactivateCareer()
  end

  publish("pendingChallengeId", nil)
  pendingStartingOptions = nil
  pendingDifficultyMode = nil
  pendingDifficultyOverrides = nil
  pendingExperimentalMaintenanceEnabled = nil
  pendingPoliceEnabled = nil
  pendingStartingGaragePreference = nil
  pendingCareerStartMode = nil
  pendingCheatsMode = nil
  pendingSandboxEconomyProfile = nil
  pendingSandboxXpProfile = nil
  publish("pendingCareerStartMode", nil)
  publish("pendingSandboxEconomyProfile", nil)
  publish("pendingSandboxXpProfile", nil)
  publish("cheatsMode", false)
  startingGaragePreference = nil
  publish("startingGaragePreference", nil)
  publish("pendingExperimentalMaintenanceEnabled", nil)
  publish("pendingPoliceEnabled", nil)
  publish("experimentalMaintenanceEnabled", nil)
  publish("policeEnabled", nil)

  log("I","",string.format("Create or Load Career: %s - %s", name, specificAutosave))

  core_jobsystem.create(function(job)
    -- Modules usually unload synchronously; bound the wait so a stuck reference cannot
    -- freeze profile loads behind the loading screen forever.
    local waited = 0
    while career_modules_playerAttributes and waited < 5 do
      print("Waiting for player attributes to be unloaded...")
      job.sleep(0.05)
      waited = waited + 0.05
    end
    if career_modules_playerAttributes then
      log("W", "", "playerAttributes still loaded after wait; continuing career load anyway")
    end

    local slotPath = career_saveSystem.getSaveRootDirectory() .. name
    local isNewSave = false

    if specificAutosave then
      local specificPath = slotPath .. "/" .. specificAutosave .. "/info.json"
      isNewSave = not FS:fileExists(specificPath)
    else
      local allSaveFolders = career_saveSystem.getAllSaveFolders(name)
      isNewSave = tableSize(allSaveFolders) == 0
    end

    if isNewSave then
      for i = 1, 3 do
        local autosaveDir = slotPath .. "/autosave" .. i
        if FS:directoryExists(autosaveDir) then
          FS:directoryRemove(autosaveDir)
        end
      end
    end

    local profileSet = false
    if career_saveSystem and career_saveSystem.isSaveBusy and career_saveSystem.isSaveBusy() then
      log("W", "", "Career start blocked; a save began while waiting to switch profiles")
    else
      profileSet = career_saveSystem.setProfile(name, specificAutosave)
    end

    if profileSet then
      local profile, savePath = career_saveSystem.getCurrentProfile()
      if savePath and isNewSave then
        local careerDir = savePath .. "/career"
        if FS:directoryExists(careerDir) then
          local files = FS:findFiles(careerDir, "*", -1, false, false)
          for _, file in ipairs(files) do
            if FS:fileExists(file) then
              FS:removeFile(file)
            elseif FS:directoryExists(file) then
              FS:directoryRemove(file)
            end
          end
        end

        if not challengeId then
          local rlsCareerDir = savePath .. "/career/rls_career"
          if FS:directoryExists(rlsCareerDir) then
            local files = FS:findFiles(rlsCareerDir, "*", -1, false, false)
            for _, file in ipairs(files) do
              if FS:fileExists(file) then
                FS:removeFile(file)
              elseif FS:directoryExists(file) then
                FS:directoryRemove(file)
              end
            end
          end
        end
      end

      pendingStartingOptions = startingOptions or {}
      publish("startingOptions", deepcopy(pendingStartingOptions))

      if tutorial then
        log("I","","Tutorial enabled.")
      end
      publish("tutorialEnabled", tutorial and true or false)
      if isNewSave then
        local selectedDifficultyMode = resolveDifficultyMode(difficultyMode, hardcore == true)
        if selectedDifficultyMode == "hardcore" then
          log("I","","Hardcore mode enabled.")
        end
        publish("hardcoreMode", selectedDifficultyMode == "hardcore")
        pendingDifficultyMode = selectedDifficultyMode
        pendingDifficultyOverrides = normalizeDifficultyOverrides(xpMultiplier, economyMultiplier, startingCash)
        -- Persist before modules activate so a crash/reload cannot lose hardcore.
        difficultyModePersist.writeModeToSave(savePath, selectedDifficultyMode, pendingDifficultyOverrides)
        pendingExperimentalMaintenanceEnabled = experimentalMaintenanceEnabled == true
        -- Hardcore always starts with no garage, regardless of UI payload.
        if selectedDifficultyMode == "hardcore" then
          pendingStartingGaragePreference = normalizeStartingGaragePreference("none", nil)
        else
          pendingStartingGaragePreference = normalizeStartingGaragePreference(startingGarageMode, startingGarageId)
        end
        publish("startingGaragePreference", deepcopy(pendingStartingGaragePreference))
        publish("pendingExperimentalMaintenanceEnabled", pendingExperimentalMaintenanceEnabled)
        publish("experimentalMaintenanceEnabled", pendingExperimentalMaintenanceEnabled)
        pendingPoliceEnabled = policeEnabled ~= false
        publish("pendingPoliceEnabled", pendingPoliceEnabled)
        publish("policeEnabled", pendingPoliceEnabled)
        -- Persist before modules activate / first autosave. Default module state is
        -- enabled=true; an early onSaveCurrentProfile would otherwise bake that in
        -- and policePreference load would ignore pending.
        do
          local dirPath = savePath .. "/career/rls_career"
          if not FS:directoryExists(dirPath) then
            FS:directoryCreate(dirPath)
          end
          career_saveSystem.jsonWriteFileSafe(dirPath .. "/policePreference.json", {
            enabled = pendingPoliceEnabled == true
          }, true)
        end
        pendingCareerStartMode = resolveCareerStartMode(careerStartMode)
        publish("pendingCareerStartMode", pendingCareerStartMode)
        pendingSandboxEconomyProfile = normalizeSandboxEconomyProfile(sandboxEconomyProfile)
        publish("pendingSandboxEconomyProfile", pendingSandboxEconomyProfile and deepcopy(pendingSandboxEconomyProfile) or nil)
        pendingSandboxXpProfile = normalizeSandboxXpProfile(sandboxXpProfile)
        publish("pendingSandboxXpProfile", pendingSandboxXpProfile and deepcopy(pendingSandboxXpProfile) or nil)
      else
        -- Existing save: sync hardcore flag from disk before career modules boot.
        local savedDifficulty = difficultyModePersist.readModeFromSave(savePath)
        if savedDifficulty then
          publish("hardcoreMode", savedDifficulty == "hardcore")
        else
          publish("hardcoreMode", false)
        end
      end
      if cheats then
        log("I","","Cheats mode enabled.")
      end
      pendingCheatsMode = cheats and true or false
      publish("cheatsMode", pendingCheatsMode)
      if challengeId then
        log("I","","Challenge enabled for later start: " .. challengeId)
      end
      publish("pendingChallengeId", challengeId)

      local mapToUse = startingMap
      if challengeId and career_challengeModes then
        local challengeOptions = career_challengeModes.getChallengeOptionsForCareerCreation()
        if challengeOptions then
          for _, challenge in ipairs(challengeOptions) do
            if challenge.id == challengeId and challenge.map then
              mapToUse = challenge.map
              log("I","","Using challenge map: " .. mapToUse)
              break
            end
          end
        end
      end
      if resolveDifficultyMode(difficultyMode, hardcore == true) == "hardcore" then
        mapToUse = nil
        log("I","","Hardcore: starting map locked to West Coast USA.")
      end

      activateCareer(true, mapToUse)
    else
      careerStartInProgress = false
      core_gamestate.requestExitLoadingScreen("careerLoading")
    end
  end)

  return true
end

local function getStartingModeOptions()
  local function sanitizeStartingModeForUi(modeData)
    return {
      id = modeData.id,
      order = modeData.order,
      tier = modeData.tier,
      title = modeData.title,
      description = modeData.description,
      image = modeData.image,
      tag = modeData.tag,
    }
  end

  local options = {}
  local files = FS:findFiles(startingModesDirectory, "*.lua", -1, true, false)

  table.sort(files)

  for _, filePath in ipairs(files) do
    local loadedOk, modeData = pcall(dofile, filePath)
    if loadedOk and type(modeData) == "table" and modeData.id and not modeData.ignore then
      table.insert(options, sanitizeStartingModeForUi(modeData))
    else
      log("W", "career.startingModes", string.format("Unable to load starting mode from '%s'", tostring(filePath)))
    end
  end

  table.sort(options, function(a, b)
    local ao = tonumber(a.order) or math.huge
    local bo = tonumber(b.order) or math.huge
    if ao ~= bo then
      return ao < bo
    end
    return tostring(a.id) < tostring(b.id)
  end)

  return deepcopy(options)
end

local function getCurrentStartingModeData()
  local startModeId = M.startingOptions and (M.startingOptions.startMode or M.startingOptions.careerStartMode)
  if type(startModeId) ~= "string" then
    return nil
  end

  local files = FS:findFiles(startingModesDirectory, "*.lua", -1, true, false)
  table.sort(files)

  for _, filePath in ipairs(files) do
    local loadedOk, modeData = pcall(dofile, filePath)
    if loadedOk and type(modeData) == "table" and modeData.id == startModeId and not modeData.ignore then
      return modeData
    end
  end

  return nil
end

local function onSaveCurrentProfile(currentSavePath)
  if not careerActive then return end

  local filePath = currentSavePath .. "/career/" .. saveFile
  local data = {}

  data.level = getCurrentLevelIdentifier()
  if switchLevel then
    data.level = switchLevel
    data.justSwitched = true
  end
  data.startingOptions = deepcopy(M.startingOptions or {})
  data.boughtStarterVehicle = boughtStarterVehicle
  data.startingGarageMode = startingGaragePreference and startingGaragePreference.mode or "default"
  data.startingGarageId = startingGaragePreference and startingGaragePreference.garageId or nil
  data.debugModuleOpenStates = {}
  data.organizationInteraction = organizationInteraction or {}
  for _, module in ipairs(debugModules) do
    if module.getDebugMenuActive then
      data.debugModuleOpenStates[module.___extensionName___] = module.getDebugMenuActive()
    end
  end

  career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function onBeforeSetProfile(currentSavePath)
  if isActive() then
    deactivateCareer()
  end
end

local function onClientStartMission(levelPath)
  if careerActive then
    publish("onUpdate", onUpdate)
    gameplay_rawPois.clear()
    setupCareerActionsAndUnpause()
    core_gamestate.setGameState("career","career", nil)
    if ui_appContainers and ui_appContainers.showApp then
      ui_appContainers.showApp("topLeft", "tasks")
    end
  end
end

local beamXPLevels ={
    {requiredValue = 0}, -- to reach lvl 1
    {requiredValue = 100},-- to reach lvl 2
    {requiredValue = 300},-- to reach lvl 3
    {requiredValue = 600},-- to reach lvl 4
    {requiredValue = 1000},-- to reach lvl 5
}
local function getBeamXPLevel(xp)
  local level = -1
  local neededForNext = -1
  local curLvlProgress = -1
  for i, lvl in ipairs(beamXPLevels) do
    if xp >= lvl.requiredValue then
      level = i
    end
  end
  if beamXPLevels[level+1] then
    neededForNext = beamXPLevels[level+1].requiredValue
    curLvlProgress = xp - beamXPLevels[level].requiredValue
  end
  return level, curLvlProgress, neededForNext
end

local SKILL_DOMAINS_DIRS = {
  "/gameplay/domains/careerSkills/skills/",
}

local skillAttributeKeyAliases = {
  ["police"] = "careerSkills-emergency",
  ["bus"] = "careerSkills-passenger",
  ["paramedic"] = "careerSkills-emergency",
  ["ambulance"] = "careerSkills-emergency",
  ["delivery"] = "logistics-delivery",
  ["vehicleDelivery"] = "logistics-delivery",
  ["materials"] = "logistics-delivery",
}

local menuSkillCache = nil

local function menuSkillCalcLevel(value, thresholds)
  local level = 0
  local prevT, nextT = 0, nil
  for i, threshold in ipairs(thresholds) do
    if value >= threshold then
      level = i
      prevT = threshold
    else
      nextT = threshold
      break
    end
  end
  local curProg, needNext = 0, 1
  if nextT then
    needNext = math.max(1, nextT - prevT)
    curProg = math.max(0, value - prevT)
  elseif level > 0 then
    curProg, needNext = 1, 1
  end
  return level, curProg, needNext
end

local function menuSkillDiscoverAll()
  if menuSkillCache then return menuSkillCache end
  menuSkillCache = {}
  local seen = {}
  for _, dir in ipairs(SKILL_DOMAINS_DIRS) do
    local files = FS:findFiles(dir, "info.json", 1, false, false)
    for _, filePath in ipairs(files or {}) do
      local info = jsonReadFile(filePath)
      if type(info) == "table" and info.isSkill == true and type(info.levels) == "table" and info.levels[1] then
        local name = info.name or ""
        if name:lower():find("coming soon") then goto skipSkill end

        local folderId = filePath:match("/([^/]+)/info%.json$")
        if not folderId then goto skipSkill end

        local attKey = info.attributeKey
        if not attKey or attKey == "" then
          attKey = skillAttributeKeyAliases[folderId] or ("careerSkills-" .. folderId)
        end
        if seen[attKey] then goto skipSkill end
        seen[attKey] = true

        local thresholds = {}
        for _, entry in ipairs(info.levels) do
          local rv = tonumber(entry.requiredValue)
          if rv then table.insert(thresholds, rv) end
        end
        table.sort(thresholds)

        table.insert(menuSkillCache, {
          id = folderId,
          label = name,
          attributeKey = attKey,
          icon = info.icon or "racing",
          color = info.color or nil,
          order = tonumber(info.order) or 9999,
          thresholds = thresholds,
          hideUntilProgress = info.hideUntilProgress == true,
        })
        ::skipSkill::
      end
    end
  end
  table.sort(menuSkillCache, function(a, b) return a.order < b.order end)
  return menuSkillCache
end

local function menuSkillReadValue(attData, attKey, useLive)
  if useLive then
    if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
      return tonumber(career_modules_playerAttributes.getAttributeValue(attKey)) or 0
    end
    return 0
  end
  if type(attData) ~= "table" or type(attKey) ~= "string" then return 0 end
  local sk = attKey
  if career_branches and career_branches.newAttributeNamesToOldNames then
    sk = career_branches.newAttributeNamesToOldNames[attKey] or attKey
  end
  local tryKeys = { sk, attKey }
  if skillAttributeKeyAliases[attKey] then
    table.insert(tryKeys, skillAttributeKeyAliases[attKey])
  end
  for alias, canonical in pairs(skillAttributeKeyAliases) do
    if canonical == attKey then table.insert(tryKeys, alias) end
  end
  for _, key in ipairs(tryKeys) do
    local blob = attData[key]
    if type(blob) == "table" then return tonumber(blob.value) or 0 end
    if type(blob) == "number" then return blob end
  end
  return 0
end

local function fillMenuProfileSkills(data, attData, useLive)
  data.freSkills = {}
  local allSkills = menuSkillDiscoverAll()
  for _, sk in ipairs(allSkills) do
    local value = menuSkillReadValue(attData, sk.attributeKey, useLive)
    if sk.hideUntilProgress and (tonumber(value) or 0) <= 0 then goto skipProfileSkill end
    local level, curProg, needNext = menuSkillCalcLevel(value, sk.thresholds)
    local icon, color = sk.icon, sk.color
    if career_branches then
      local b = career_branches.getBranchById(sk.attributeKey) or career_branches.getBranchByPath(sk.attributeKey)
      if type(b) == "table" then
        if b.icon then icon = b.icon end
        if b.color then color = b.color end
      end
    end
    table.insert(data.freSkills, {
      id = sk.id,
      label = sk.label,
      skillKey = sk.attributeKey,
      icon = icon,
      color = color,
      level = level,
      value = value,
      curLvlProgress = curProg,
      neededForNext = needNext,
      levelLabel = { txt = 'ui.career.lvlLabel', context = { lvl = level } },
    })
    ::skipProfileSkill::
  end
end

-- purchasedGarages.json stores {garages = {[id] = true}}, so there is nothing to
-- take a length of — the owned count is the number of keys.
local function countPurchasedGarages(autosavePath)
  local data = jsonReadFile(autosavePath .. "/career/rls_career/purchasedGarages.json")
  if type(data) ~= "table" or type(data.garages) ~= "table" then return 0 end
  return tableSize(data.garages)
end

--[[
  The newest money movements, newest first.

  attributeLog.json is append-ordered and grows for the life of a save, so this
  walks it backwards and stops as soon as it has enough. It is deliberately kept
  out of formatProfileForUi: that runs for every profile on the select screen,
  and this is the one file per save that is not small.
]]
local function summariseRecentMoney(log, limit)
  local res = {}
  if type(log) ~= "table" then return res end
  limit = limit or 5

  for i = #log, 1, -1 do
    local entry = log[i]
    local amount = type(entry) == "table" and type(entry.attributeChange) == "table"
      and tonumber(entry.attributeChange.money) or nil
    -- Either a translation key or a {txt, context} table; the UI translates it.
    local label = type(entry) == "table" and type(entry.reason) == "table" and entry.reason.label or nil
    -- Unlabelled entries (fuel, incidental charges) would render as a row reading
    -- "Transaction" and a number, which says nothing. Skip to the next real one.
    if amount and amount ~= 0 and label then
      table.insert(res, {amount = amount, label = label, time = entry.time})
      if #res >= limit then break end
    end
  end

  return res
end

--[[
  What one vehicle is worth now.

  Age and mileage only — the same curve the shops price against, but without the
  per-part and damage terms, which need the vehicle actually loaded. Computed the
  same way whether or not the save is running, so the figure does not change
  depending on which profile happens to be open.
]]
local function vehicleAssetValue(vehicle)
  local base = tonumber(vehicle and vehicle.configBaseValue) or 0
  if base <= 0 then return 0 end
  if not (career_modules_valueCalculator and career_modules_valueCalculator.getQuickVehicleValue) then
    return base
  end
  return tonumber(career_modules_valueCalculator.getQuickVehicleValue(base, vehicle.year, vehicle.mileage)) or base
end

-- Save paths are stored relative; the UI needs one it can put in an img src.
local function toUiPath(path)
  if type(path) ~= "string" or path == "" then return nil end
  if path:sub(1, 1) ~= "/" then return "/" .. path end
  return path
end

local function currentVehicleHighlight(autosavePath, vehicle, currentId)
  if not currentId then return nil end
  local res = {
    name = vehicle and (vehicle.niceName or vehicle.model) or nil,
    location = vehicle and vehicle.niceLocation or nil,
  }
  -- Written only when the save was taken with a thumbnail pass, so it can be
  -- absent. The game writes .jpg today; migrated 0.39 saves carry .png.
  local base = autosavePath .. "/career/vehicles/" .. tostring(currentId)
  for _, ext in ipairs({".jpg", ".png"}) do
    if FS:fileExists(base .. ext) then
      res.image = toUiPath(base .. ext)
      break
    end
  end
  if not res.name and not res.image then return nil end
  return res
end

local function isKnownCareerProfile(profileName)
  if type(profileName) ~= "string" or profileName == "" then
    return false
  end
  for _, name in ipairs(career_saveSystem.getAllProfiles()) do
    if name == profileName then
      return true
    end
  end
  return false
end

local function setMaintenanceModeForSaveSlot(slotName, enabled)
  if not isKnownCareerProfile(slotName) then
    return false
  end
  local autosavePath = getNewestSaveForProfile(slotName)
  if not autosavePath or autosavePath == "" then
    return false
  end
  local dirPath = autosavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local filePath = dirPath .. "/maintenanceMode.json"
  local data = {enabled = enabled == true}
  if not career_saveSystem.jsonWriteFileSafe(filePath, data, true) then
    return false
  end
  local currentProfile, currentPath = career_saveSystem.getCurrentProfile()
  if careerActive and currentProfile == slotName and currentPath == autosavePath then
    if career_modules_maintenanceMode and career_modules_maintenanceMode.setEnabled then
      career_modules_maintenanceMode.setEnabled(data.enabled)
    end
  end
  return true
end

local function setPoliceEnabledForSaveSlot(slotName, enabled)
  if not isKnownCareerProfile(slotName) then
    return false
  end
  local autosavePath = getNewestSaveForProfile(slotName)
  if not autosavePath or autosavePath == "" then
    return false
  end
  local dirPath = autosavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local filePath = dirPath .. "/policePreference.json"
  local data = {enabled = enabled == true}
  if not career_saveSystem.jsonWriteFileSafe(filePath, data, true) then
    return false
  end
  -- Never apply mid-session. Persist for next load and keep runtime police as-is.
  local currentProfile, currentPath = career_saveSystem.getCurrentProfile()
  if careerActive and currentProfile == slotName and currentPath == autosavePath then
    if career_modules_policePreference and career_modules_policePreference.setEnabledForNextLoad then
      career_modules_policePreference.setEnabledForNextLoad(data.enabled)
    end
  end
  return true
end

local function formatProfileForUi(profile)
  local data = {}
  data.id = profile

  local levelPreviewMap = {
    west_coast_usa = "/ui/modules/career/profilePreview_WCUSA.jpg"
  }

  local autosavePath = getNewestSaveForProfile(profile)
  if not autosavePath then
    -- The folder exists but holds no readable save. The UI gets only an id, so
    -- say why rather than letting the card render "-" and $0 as real values.
    data.saveDataMissing = true
    return data
  end
  local infoData = jsonReadFile(autosavePath .. "/info.json")
  local careerData = jsonReadFile(autosavePath .. "/career/" .. saveFile)
  local generalData = careerData
  local difficultyData = jsonReadFile(difficultyModePersist.getSaveFilePath(autosavePath))
  local hardcoreData = jsonReadFile(difficultyModePersist.getLegacyHardcorePath(autosavePath))
  local cheatsData = jsonReadFile(autosavePath .. "/career/rls_career/cheats.json")
  local challengeData = jsonReadFile(autosavePath .. "/career/rls_career/challengeModes.json")
  local maintenanceModeData = jsonReadFile(autosavePath .. "/career/rls_career/maintenanceMode.json")
  local policePreferenceData = jsonReadFile(autosavePath .. "/career/rls_career/policePreference.json")
  local careerStartModeData = jsonReadFile(autosavePath .. "/career/rls_career/careerStartMode.json")

  if careerStartModeData and careerStartModeData.careerStartMode then
    data.careerStartMode = careerStartModeData.careerStartMode
  elseif cheatsData and cheatsData.cheatsMode then
    data.careerStartMode = "freeroam"
  elseif challengeData and challengeData.activeChallenge then
    data.careerStartMode = "story"
  elseif (difficultyData and difficultyData.mode == "hardcore") or (hardcoreData and hardcoreData.hardcoreMode) then
    data.careerStartMode = "hardcore"
  end

  if difficultyData and difficultyData.mode then
    data.difficultyMode = difficultyData.mode
    data.hardcoreMode = difficultyData.mode == "hardcore"
  elseif hardcoreData then
    data.hardcoreMode = hardcoreData.hardcoreMode
    data.difficultyMode = hardcoreData.hardcoreMode and "hardcore" or "normal"
  end

  if cheatsData then
    data.cheatsMode = cheatsData.cheatsMode
  end

  if challengeData and challengeData.activeChallenge then
    data.activeChallenge = challengeData.activeChallenge.name
  end

  if careerData and careerData.level then
    -- The featured card names the map it is parked on, so send the id too and
    -- let the UI resolve it against overhaul_maps' label table.
    data.level = careerData.level
    if levelPreviewMap[careerData.level] then
      data.preview = levelPreviewMap[careerData.level]
    else
      local preview = "/ui/modules/career/profilePreview_" .. careerData.level .. ".jpg"
      if FS:fileExists(preview) then
        data.preview = preview
      else
        data.preview = levelPreviewMap.west_coast_usa
      end
    end
  end

  local currentProfile, _ = career_saveSystem.getCurrentProfile()
  if career_career.isActive() and currentProfile == profile then
    -- Prefer saved/deferred preference so profile UI can show next-load state.
    if policePreferenceData and policePreferenceData.enabled ~= nil then
      data.policeEnabled = policePreferenceData.enabled == true
    elseif career_modules_policePreference and career_modules_policePreference.getSavedEnabled then
      data.policeEnabled = career_modules_policePreference.getSavedEnabled() == true
    elseif career_modules_policePreference and career_modules_policePreference.isEnabled then
      data.policeEnabled = career_modules_policePreference.isEnabled() == true
    else
      data.policeEnabled = M.policeEnabled ~= false
    end

    data.tutorialActive = (career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive()) or false
    data.money = career_modules_playerAttributes.getAttribute("money")
    data.beamXP = career_modules_playerAttributes.getAttribute("beamXP")
    data.vouchers = career_modules_playerAttributes.getAttribute("vouchers")
    data.insuranceScore = {value = career_modules_insurance_insurance.getDriverScore()}
    data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = getBeamXPLevel(data.beamXP.value)
    data.branches = {}

    for _, br in ipairs(career_branches.getSortedBranches()) do
      if br.isBranch and br.parentDomain == "apm" then
        local attKey = br.attributeKey
        local brData = deepcopy(career_modules_playerAttributes.getAttribute(attKey) or {value=br.defaultValue or 0})
        brData.level, brData.curLvlProgress, brData.neededForNext = career_branches.calcBranchLevelFromValue(brData.value, br.id)
        brData.id = attKey
        brData.icon = br.icon
        brData.color = br.color
        brData.label = br.name
        brData.levelLabel = {txt='ui.career.lvlLabel', context={lvl=brData.level}}
        table.insert(data.branches, brData)
        -- remove this assigment once UI side works with the new branch list
        data[attKey] = brData
      end
    end
    fillMenuProfileSkills(data, nil, true)
    local currentId = career_modules_inventory.getCurrentVehicle()
    data.currentVehicle = currentId and deepcopy(career_modules_inventory.getVehicles()[currentId])
    if data.currentVehicle and career_modules_inventory.getVehicleNiceNameTranslated then
      data.currentVehicle.niceName = career_modules_inventory.getVehicleNiceNameTranslated(currentId)
    end

    -- Ships with the card rather than with the highlights: the card's artwork
    -- would otherwise rearrange itself a beat after appearing.
    if currentId and data.currentVehicle then
      data.lastVehicle = currentVehicleHighlight(autosavePath, data.currentVehicle, currentId)
    end

    data.vehicleCount = tableSize(career_modules_inventory.getVehicles() or {})

    if career_modules_garageManager and career_modules_garageManager.getPurchasedGarages then
      data.garageCount = #career_modules_garageManager.getPurchasedGarages()
    else
      data.garageCount = countPurchasedGarages(autosavePath)
    end
  else
    -- profile from file
    if policePreferenceData and policePreferenceData.enabled ~= nil then
      data.policeEnabled = policePreferenceData.enabled == true
    else
      data.policeEnabled = true
    end
    local attData = jsonReadFile(autosavePath .. "/career/playerAttributes.json")
    local inventoryData = jsonReadFile(autosavePath .. "/career/inventory.json")
    local insuranceData = jsonReadFile(autosavePath .. "/career/insurance.json")

    if attData then
      data.money = deepcopy(attData.money) or {value=0}
      data.beamXP = deepcopy(attData.beamXP) or {value=0}
      data.vouchers = deepcopy(attData.vouchers) or {value=0}
      if insuranceData and insuranceData.plDriverScore then
        data.insuranceScore = {value = insuranceData.plDriverScore}
      else
        data.insuranceScore = {value = 0}
      end
      data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = getBeamXPLevel(data.beamXP.value)
      data.branches = {}
      for _, br in ipairs(career_branches.getSortedBranches()) do
        if br.isBranch and br.parentDomain == "apm" then
          local attKey = br.attributeKey
          local newAttKey = career_branches.newAttributeNamesToOldNames[attKey] or attKey
          local brData = deepcopy(attData[newAttKey] or attData[attKey] or {value=br.defaultValue or 0})
          brData.level, brData.curLvlProgress, brData.neededForNext = career_branches.calcBranchLevelFromValue(brData.value, br.id)
          brData.id = attKey
          brData.icon = br.icon
          brData.color = br.color
          brData.label = br.name
          brData.levelLabel = {txt='ui.career.lvlLabel', context={lvl=brData.level}}

          table.insert(data.branches, brData)
          -- remove this assigment once UI side works with the new branch list
          data[attKey] = brData
        end
      end
      fillMenuProfileSkills(data, attData, false)
    else
      data.freSkills = {}
      -- The slot exists on disk but was never written past creation, so there is
      -- no money, XP or date to report. Flag it rather than letting the UI render
      -- $0 and "-" as though they were real values.
      data.saveDataMissing = true
    end

    if inventoryData and inventoryData.currentVehicle then
      local vehicleData = jsonReadFile(autosavePath .. "/career/vehicles/" .. inventoryData.currentVehicle .. ".json")
      if vehicleData then
        data.currentVehicle = vehicleData.niceName
        -- One extra record and a file check, next to reads this already does.
        data.lastVehicle = currentVehicleHighlight(autosavePath, vehicleData, inventoryData.currentVehicle)
      end
    end
    local files = FS:findFiles(autosavePath .. "/career/vehicles/", '*.json', 0, false, false)
    data.vehicleCount = #files
    data.garageCount = countPurchasedGarages(autosavePath)
  end

  if careerActive and career_career.isActive() and currentProfile == profile and career_modules_maintenanceMode and career_modules_maintenanceMode.isEnabled then
    data.experimentalMaintenanceEnabled = career_modules_maintenanceMode.isEnabled() == true
  else
    data.experimentalMaintenanceEnabled = maintenanceModeData and maintenanceModeData.enabled == true or false
  end

  if generalData then
    data.boughtStarterVehicle = generalData.boughtStarterVehicle
    data.startingOptions = generalData.startingOptions or {}
  end
  -- add the infoData raw
  if infoData and infoData.version then
    infoData.incompatibleVersion = career_saveSystem.getBackwardsCompVersion() > infoData.version
    infoData.outdatedVersion = career_saveSystem.getSaveSystemVersion() > infoData.version
    tableMerge(data, infoData)
  end

  return data
end

local function collectAllProfilesData()
  local res = {}
  local allProfiles = career_saveSystem.getAllProfiles()
  if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
    util_asyncBulkLoader.addTotal(#allProfiles)
  end
  for _, profile in ipairs(allProfiles) do
    local profileData = formatProfileForUi(profile)
    if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
      util_asyncBulkLoader.addCount(1)
      util_asyncBulkLoader.yield("sendAllCareerProfilesData " .. profile)
    end
    if profileData then
      table.insert(res, profileData)
    end
  end

  table.sort(res, function(a,b) return (a.creationDate or "Z") < (b.creationDate or "Z") end)
  return res
end

local function sendAllCareerProfilesData()
  local res = collectAllProfilesData()
  guihooks.trigger("allCareerProfiles", res)
  return res
end

local function sendAllCareerSaveSlotsData()
  local res = collectAllProfilesData()
  guihooks.trigger("allCareerSaveSlots", res)
  return res
end

-- Scrolling back over a card must not pay for the same file reads twice. Keyed
-- on the save folder and its date, so a save written since is not served stale.
local highlightsCache = {}

-- Called by the profile screen for the selected card only, never for the strip:
-- this reads the attribute log and every vehicle file, which the strip must not do
-- once per profile.
local function getProfileHighlights(profile, limit)
  local res = {recentMoney = {}, assetValue = 0}
  if not isKnownCareerProfile(profile) then return res end
  limit = tonumber(limit) or 5

  local autosavePath, saveDate = getNewestSaveForProfile(profile)
  saveDate = saveDate or ""
  if not autosavePath then return res end

  local currentProfile = career_saveSystem.getCurrentProfile()
  local isLoaded = career_career.isActive() and currentProfile == profile

  -- The loaded save reads live state, which changes under us, so it is never cached.
  local cacheKey
  if not isLoaded then
    cacheKey = autosavePath .. "|" .. tostring(limit)
    local hit = highlightsCache[cacheKey]
    if hit and hit.date == saveDate then return hit.data end
  end

  if isLoaded and career_modules_playerAttributes and career_modules_playerAttributes.getAttributeLog then
    -- The log on disk is only as fresh as the last autosave.
    res.recentMoney = summariseRecentMoney(career_modules_playerAttributes.getAttributeLog(), limit)
  else
    res.recentMoney = summariseRecentMoney(jsonReadFile(autosavePath .. "/career/attributeLog.json"), limit)
  end

  if isLoaded and career_modules_inventory then
    for _, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
      res.assetValue = res.assetValue + vehicleAssetValue(vehicle)
    end
  else
    for _, file in ipairs(FS:findFiles(autosavePath .. "/career/vehicles/", "*.json", 0, false, false)) do
      res.assetValue = res.assetValue + vehicleAssetValue(jsonReadFile(file))
    end
  end
  res.assetValue = math.floor(res.assetValue)

  if cacheKey then highlightsCache[cacheKey] = {date = saveDate, data = res} end

  return res
end

local function sendCurrentProfileData()
  if not careerActive then return end
  local profile = career_saveSystem.getCurrentProfile()
  if profile then
    return formatProfileForUi(profile)
  end
end

local function getAutosavesForProfile(profile)
  local res = {}
  for _, saveData in ipairs(career_saveSystem.getAllSaveFolders(profile)) do
    local data = jsonReadFile(career_saveSystem.getSaveRootDirectory() .. profile .. "/" .. saveData.name .. "/career/playerAttributes.json")
    if data then
      data.id = profile
      data.autosaveName = saveData.name
      table.insert(res, data)
    end
  end
  return res
end

-- Returns the list of save folders (autosaves) for a profile with enough info
-- for the UI to display and let the player pick one to load.
local function getSaveFoldersForProfile(profile)
  local res = {}
  if not profile then return res end
  local saveRootDir = career_saveSystem.getSaveRootDirectory()
  local curProfile, curSavePath = career_saveSystem.getCurrentProfile()
  local curFolderName = curSavePath and string.match(curSavePath, "([^/\\]+)$") or nil
  for _, saveData in ipairs(career_saveSystem.getAllSaveFolders(profile)) do
    local folderPath = saveRootDir .. profile .. "/" .. saveData.name
    local entry = {
      id = profile,
      name = saveData.name,
      date = saveData.date,
      creationDate = saveData.creationDate,
      displayName = saveData.displayName or profile,
      corrupted = saveData.corrupted and true or false,
      version = saveData.version,
      isCurrent = (curProfile == profile and curFolderName == saveData.name) or false,
    }
    if saveData.version then
      entry.incompatibleVersion = career_saveSystem.getBackwardsCompVersion() > saveData.version
      entry.outdatedVersion = career_saveSystem.getSaveSystemVersion() > saveData.version
    end

    local attData = jsonReadFile(folderPath .. "/career/playerAttributes.json")
    if attData then
      entry.money = attData.money or {value = 0}
      entry.beamXP = attData.beamXP or {value = 0}
    end

    local vehicleFiles = FS:findFiles(folderPath .. "/career/vehicles/", '*.json', 0, false, false)
    entry.vehicleCount = #vehicleFiles

    table.insert(res, entry)
  end

  -- newest first
  table.sort(res, function(a, b) return (a.date or "0") > (b.date or "0") end)
  return res
end

local function switchCareerLevel(nextLevel)
  if type(nextLevel) ~= "string" or nextLevel == "" then
    return false, "A destination level is required"
  end
  if not careerActive then
    return false, "Career is not active"
  end
  if levelSwitchTransaction then
    return false, "Map travel is already in progress"
  end

  local currentLevel = getCurrentLevelIdentifier()
  if nextLevel == currentLevel then
    return false, "Already in the requested destination"
  end

  local compatibleMaps = overhaul_maps and overhaul_maps.getCompatibleMaps and overhaul_maps.getCompatibleMaps() or nil
  if type(compatibleMaps) ~= "table" or compatibleMaps[nextLevel] == nil then
    return false, "Destination is not registered as a compatible career map: " .. nextLevel
  end
  if not FS:directoryExists("/levels/" .. nextLevel) then
    return false, "Destination level is unavailable: " .. nextLevel
  end

  levelSwitchSequence = levelSwitchSequence + 1
  levelSwitchTransaction = {
    source = currentLevel,
    destination = nextLevel,
    phase = "saving",
    retryCount = 0,
    sequence = levelSwitchSequence,
    startedAt = os.time(),
  }
  switchLevel = nextLevel
  lastLevelSwitchResult = {phase = "inProgress"}

  if not core_gamestate.getLoadingStatus("careerLoading") then
    core_gamestate.requestEnterLoadingScreen("careerLoading")
  end
  extensions.hook("onBeforeCareerLevelSwitch", currentLevel, nextLevel)
  startLevelSwitchSaveWatchdog(levelSwitchSequence)
  career_saveSystem.saveCurrent(nil, true)
  return true
end

local function onClientEndMission(levelPath)
  if not careerActive then return end
  deactivateCareer()
end

local function onSerialize()
  local data = {}
  if careerActive then
    data.reactivate = true
    deactivateCareer()
  end
  return data
end

local function onDeserialized(v)
  if v.reactivate then
    activateCareer(false)
  end
end

local function sendCurrentSaveSlotName()
  guihooks.trigger("currentSaveSlotName", {saveSlot = career_saveSystem.getCurrentProfile()})
end

local function launchMostRecentCareer()
  local allProfiles = career_saveSystem.getAllProfiles()
  if tableSize(allProfiles) == 0 then
    log("W", "", "No career save slots found")
    return false
  end

  local mostRecentProfile = nil
  local mostRecentDate = "0"

  for _, profileName in ipairs(allProfiles) do
    local _, saveDate = getNewestSaveForProfile(profileName)
    if saveDate and saveDate ~= "0" and saveDate ~= "A" then
      if saveDate > mostRecentDate then
        mostRecentDate = saveDate
        mostRecentProfile = profileName
      end
    end
  end

  if not mostRecentProfile then
    log("W", "", "No valid career saves found")
    return false
  end

  log("I", "", "Launching most recent career: " .. mostRecentProfile)
  return createOrLoadCareerAndStart(mostRecentProfile)
end

local function onAnyMissionChanged(state, mission)
  if not careerActive then return end
  if mission then
    if state == "stopped" then
      blockInputActions(true)
    elseif state == "started" then
      blockInputActions(false)
    end
  end
end

local function hasBoughtStarterVehicle()
  return boughtStarterVehicle
end

local function setBoughtStarterVehicle(value)
  boughtStarterVehicle = value == true
end

local function hasInteractedWithOrganization(id)
  return organizationInteraction[id]
end

local function interactWithOrganization(id)
  organizationInteraction[id] = true
end

local function onVehicleAddedToInventory(data)
  -- if data.vehicleInfo is present, then the vehicle was bought
  if not boughtStarterVehicle and data.vehicleInfo then
    boughtStarterVehicle = true
    career_modules_vehicleShopping.updateVehicleList(true)
  end
end

local function isAutosaveEnabled()
  return autosaveEnabled
end

local function setAutosaveEnabled(enabled)
  autosaveEnabled = enabled
end

local function getAdditionalMenuButtons()
  local ret = {}
  if career_modules_delivery_general.isDeliveryModeActive() then
    table.insert(ret, {label = "Map (My Cargo)", luaFun = "career_modules_delivery_cargoScreen.enterMyCargo()"})
  else
    table.insert(ret, {label = "Map", luaFun = "freeroam_bigMapMode.enterBigMap({instant=true})"})
  end
  local tutorialActive = career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive()
  if not tutorialActive and M.hasBoughtStarterVehicle() then
    table.insert(ret, {label = "Progress", luaFun = "guihooks.trigger('ChangeState', {state = 'career.domainSelection'})", showIndicator = career_modules_milestones_milestones.unclaimedMilestonesCount() > 0})
  end
  if career_modules_vehiclePerformance.isTestInProgress() then
    table.insert(ret, {label = "Cancel Certification", luaFun = "career_modules_vehiclePerformance.cancelTest()", showIndicator = true})
  end

  if career_modules_testDrive.isActive() then
    table.insert(ret, {label = "Cancel Test Drive", luaFun = "career_modules_testDrive.stop()", showIndicator = true})
  end
  return ret
end

local function setDebugMenuEnabled(enabled)
  debugMenuEnabled = enabled
end

local function onWorldReadyState(state)
  if state ~= 2 then return end

  if levelSwitchTransaction then
    levelSwitchTransaction.phase = "activating"
    if careerActive then
      -- Some level handoffs do not emit onClientEndMission. Never carry modules
      -- initialized for the source map into the destination world.
      log("W", "career", "Career remained active through map handoff; reloading destination modules")
      deactivateCareer(false)
      blockInputActions(true)
    end
    activateCareer(false, levelSwitchTransaction.destination)
  end

  -- Mid-session (or deferred) profile load: level is up, now activate on the new save.
  if pendingProfileLoad then
    local opts = pendingProfileLoad
    pendingProfileLoad = nil
    if not careerActive then
      activateCareer(opts.removeVehicles, opts.levelToLoad)
    end
  end
end

-- Fallback only: activateCareer now finishes careerLoading. Keep this for spawns that
-- still hit vehicle-group hooks before activate's freeroam callback runs.
local function onVehicleGroupSpawned()
  if careerLoadingIntroStarted and not core_gamestate.getLoadingStatus("careerLoading") then
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(0.25)
    finishCareerLoadingIntro({ setCamera = true })
  end)
end

local function onSaveFinished()
  if levelSwitchTransaction and levelSwitchTransaction.phase == "saving" then
    levelSwitchTransaction.phase = "loadingLevel"
    local sequence = levelSwitchTransaction.sequence
    core_jobsystem.create(function(job)
      job.sleep(0.01)
      if not levelSwitchTransaction or levelSwitchTransaction.sequence ~= sequence then return end
      if careerActive then
        deactivateCareer(false)
        -- Keep reset/teleport/free-roam actions gated while the destination loads.
        blockInputActions(true)
      end
      spawn.preventPlayerSpawning = true
      freeroam_freeroam.startFreeroam(path.getPathLevelMain(levelSwitchTransaction.destination), nil, false, nil, function()
        server.fadeoutLoadingScreen()
      end)
    end)
  end
end

local function onCareerSaveFailed(savePath)
  if levelSwitchTransaction and levelSwitchTransaction.phase == "saving" then
    failLevelSwitch("Career save failed before map travel" .. (savePath and (": " .. tostring(savePath)) or ""))
  end
end

-- Keep migration UI calls on the long-lived career bridge. Newly loaded extension
-- names are not guaranteed to be present in the Vue Lua proxy for an existing UI.
local function getLegacySavePreflight(profile, specificSaveFolder)
  if not career_saveMigration then
    return {canMigrate = false, blockerCount = 1, error = "Career migration service is unavailable."}
  end
  return career_saveMigration.getLegacySavePreflight(profile, specificSaveFolder)
end

local function prepareLegacySaveMigration(profile, specificSaveFolder, options)
  if not career_saveMigration then
    endLegacySaveMigrationLoading()
    return {ok = false, error = "Career migration service is unavailable."}
  end
  local result = career_saveMigration.prepareLegacySaveMigration(profile, specificSaveFolder, options)
  -- Nothing will load after a failed copy, so never leave the migration screen up,
  -- even if the UI that raised it is already gone.
  if type(result) ~= "table" or not result.ok then
    endLegacySaveMigrationLoading()
  end
  return result
end

M.createOrLoadCareerAndStart = createOrLoadCareerAndStart
M.activateCareer = activateCareer
M.deactivateCareer = deactivateCareer
M.deactivateCareerAndReloadLevel = deactivateCareerAndReloadLevel
M.isActive = isActive
M.applyChallengeConfig = applyChallengeConfig
M.switchCareerLevel = switchCareerLevel
M.getLevelSwitchState = getLevelSwitchState
M.getActivationHealth = getActivationHealth
M.launchMostRecentCareer = launchMostRecentCareer

M.sendAllCareerProfilesData = sendAllCareerProfilesData
M.sendCurrentProfileData = sendCurrentProfileData
M.getAutosavesForProfile = getAutosavesForProfile
M.getSaveFoldersForProfile = getSaveFoldersForProfile
M.getProfileHighlights = getProfileHighlights
M.getStartingModeOptions = getStartingModeOptions
M.getCurrentStartingModeData = getCurrentStartingModeData

M.sendAllCareerSaveSlotsData = sendAllCareerSaveSlotsData
M.sendCurrentSaveSlotData = sendCurrentProfileData
M.getAutosavesForSaveSlot = getAutosavesForProfile
M.sendCurrentSaveSlotName = sendCurrentSaveSlotName
M.setMaintenanceModeForSaveSlot = setMaintenanceModeForSaveSlot
M.setPoliceEnabledForSaveSlot = setPoliceEnabledForSaveSlot

M.hasBoughtStarterVehicle = hasBoughtStarterVehicle
M.setBoughtStarterVehicle = setBoughtStarterVehicle
M.hasInteractedWithOrganization = hasInteractedWithOrganization
M.interactWithOrganization = interactWithOrganization
M.closeAllMenus = closeAllMenus
M.isAutosaveEnabled = isAutosaveEnabled
M.setAutosaveEnabled = setAutosaveEnabled
M.getBeamXPLevel = getBeamXPLevel
M.setDebugMenuEnabled = setDebugMenuEnabled
M.getStartingGaragePreference = getStartingGaragePreference
M.setStartingGaragePreference = setStartingGaragePreference
M.getAdditionalMenuButtons = getAdditionalMenuButtons
M.getLegacySavePreflight = getLegacySavePreflight
M.prepareLegacySaveMigration = prepareLegacySaveMigration
M.beginLegacySaveMigrationLoading = beginLegacySaveMigrationLoading
M.endLegacySaveMigrationLoading = endLegacySaveMigrationLoading

M.onSaveCurrentProfile = onSaveCurrentProfile
M.onBeforeSetProfile = onBeforeSetProfile
M.onCareerActive = onCareerActive
M.onSaveFinished = onSaveFinished
M.onCareerSaveFailed = onCareerSaveFailed
M.onWorldReadyState = onWorldReadyState
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onCameraModeChanged = onCameraModeChanged
M.onGlobalCameraSet = onGlobalCameraSet
M.onCheatsModeChanged = onCheatsModeChanged

return M
