local M = {}

M.dependencies = {'career_career'}

local loadedExtensions = {}

local function loadExtensions()
  local basePath = "/lua/ge/extensions/gameplay/events/freContracts/"
  local files = FS:findFiles(basePath, "*.lua", -1, true, false)

  if files then
    for _, filePath in ipairs(files) do
      local filename = string.match(filePath, "([^/]+)%.lua$")
      if filename then
        local extensionName = "gameplay_events_freContracts_" .. filename
        setExtensionUnloadMode(extensionName, "manual")
        extensions.unload(extensionName)
        table.insert(loadedExtensions, extensionName)
      end
    end
  end
  loadManualUnloadExtensions()
end

local function unloadExtensions()
  for _, extensionName in ipairs(loadedExtensions) do
    extensions.unload(extensionName)
  end
  loadedExtensions = {}
end

local function onUpdate(_, dtSim, _)
  if not gameplay_events_freContracts_state.isCareerActive() then
    return
  end
  gameplay_events_freContracts_state.updateSimTime(dtSim)
  local now = gameplay_events_freContracts_state.getSimTime()
  local nextMaintenanceAt = gameplay_events_freContracts_state.getNextMaintenanceAt()
  if not nextMaintenanceAt or now < nextMaintenanceAt then
    return
  end

  local changed = false
  if gameplay_events_freContracts_skills.pruneAllSponsorSlotCooldowns(now) then
    changed = true
    gameplay_events_freContracts_state.saveNow()
  end
  if gameplay_events_freContracts_offers.purgeExpiredEntries(now) then
          changed = true
  end
  if gameplay_events_freContracts_offers.syncAllOffers(now) then
          changed = true
  end
  if gameplay_events_freContracts_sanctionedRacing.syncGeneration(now) then
    changed = true
  end
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
  gameplay_events_freContracts_state.preventImmediateRetrigger(now)
  if changed then
    gameplay_events_freContracts_ui.emitUiStateUpdate("maintenance")
  end
end

local function onSaveCurrentProfile(currentSavePath)
  local state = gameplay_events_freContracts_state.getState()
  if not state then
    return
  end
  gameplay_events_freContracts_state.saveState(currentSavePath)
end

local function onExtensionLoaded()
  loadExtensions()
  gameplay_events_freContracts_state.loadState()
  gameplay_events_freContracts_raceCache.refreshRaceCache()
  local now = gameplay_events_freContracts_state.getSimTime()
  gameplay_events_freContracts_offers.purgeExpiredEntries(now)
  gameplay_events_freContracts_offers.syncAllOffers(now)
  if gameplay_events_freContracts_sanctionedRacing.evictStaleOfferOnCareerLoad then
    gameplay_events_freContracts_sanctionedRacing.evictStaleOfferOnCareerLoad()
  end
  gameplay_events_freContracts_sanctionedRacing.syncGeneration(now)
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
end

local function onExtensionUnloaded()
  unloadExtensions()
end

local function onCareerModulesActivated()
  gameplay_events_freContracts_state.loadState()
  gameplay_events_freContracts_raceCache.refreshRaceCache()
  local now = gameplay_events_freContracts_state.getSimTime()
  -- Drop any leftover "committed"/"racing" sanctioned offer from a previous session; runtime is fresh
  -- on load (no scenario, no HUD suppression) so the offer has no live race behind it and would
  -- otherwise block every future commitAndNavigateExternalOffer accept with "already committed".
  if gameplay_events_freContracts_sanctionedRacing.evictStaleOfferOnCareerLoad then
    gameplay_events_freContracts_sanctionedRacing.evictStaleOfferOnCareerLoad()
  end
  gameplay_events_freContracts_sanctionedRacing.syncGeneration(now)
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
