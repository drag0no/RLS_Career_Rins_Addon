local M = {}

local ourModName = "rls_career_overhaul"
local ourModId = "RLSCO24"

local commandCallback = nil
local devKey = "dc124d6fb1a6261f"

-- BeamNG can build its normal-action cache before unpacked mods finish
-- mounting. In that case the files are visible later, but custom actions remain
-- absent until the cache is invalidated.
local requiredInputActionFiles = {
    {
        path = "/lua/ge/extensions/core/input/actions/phone.json",
        actions = {"openPhone"}
    },
    {
        path = "/lua/ge/extensions/core/input/actions/rls_yankem.json",
        actions = {"rlsYankemToggle", "rlsYankemReelIn", "rlsYankemReelOut", "rlsYankemSelect"}
    }
}

local function ensureInputActionsRegistered()
    if not core_input_actions then
        log("E", "extensionManager", "core_input_actions is unavailable")
        return false
    end

    local actions = core_input_actions.getActiveActions() or {}
    local missingFiles = {}
    for _, spec in ipairs(requiredInputActionFiles) do
        for _, actionName in ipairs(spec.actions) do
            if not actions[actionName] then
                table.insert(missingFiles, spec)
                break
            end
        end
    end

    if #missingFiles == 0 then
        return true
    end

    if type(core_input_actions.onFileChanged) == "function" then
        for _, spec in ipairs(missingFiles) do
            core_input_actions.onFileChanged(spec.path)
        end
        actions = core_input_actions.getActiveActions() or {}
    end

    local allRegistered = true
    for _, spec in ipairs(requiredInputActionFiles) do
        for _, actionName in ipairs(spec.actions) do
            if not actions[actionName] then
                log("E", "extensionManager", "Failed to register input action: " .. actionName)
                allRegistered = false
            end
        end
    end
    if not allRegistered then return false end

    -- Bindings may have been parsed before the action existed and skipped as
    -- invalid. Ask the bindings module to reread them now that actions exist.
    if core_input_bindings and type(core_input_bindings.onFileChanged) == "function" then
        for _, spec in ipairs(missingFiles) do
            core_input_bindings.onFileChanged(spec.path)
        end
    end

    log("I", "extensionManager", "Registered mod input actions after mount")
    return true
end


local function checkVersion()
    local fileData = jsonReadFile("integrity.json")
    if fileData.version then
        local version = fileData.version
        local versionParts = string.split(version, ".")
        if versionParts[4] ~= "9" then
            guihooks.trigger("toastrMsg", {type="error", title="Update required", msg="RLS Career Overhaul is outdated. Please update to the latest version either from Patreon or Github."})
            return false
        end
    end
    return true
end

-- BeamNG's own tech_techCore declares its dependencies in path form
-- ('scenario/scenariosLoader', 'util/trackBuilder/proceduralPrimitives'), so those
-- modules end up registered under an extension name that contains no underscore.
-- On a Lua reload (Ctrl+L) extensions.deserialize runs
--   root = string.sub(extName, 1, string.find(extName, "_") - 1)
-- for every name whose path form doesn't round-trip, which throws on the nil and
-- aborts the ENTIRE extension restore pass -- every mod extension, the career, and
-- the tech bridge all fail to come back. Keeping these names out of the snapshot
-- sidesteps it; whoever depends on them re-pulls them on the next load anyway.
local serializationBlocked = {}
local function blockUnreloadableExtensionNames()
    if not extensions.getLoadedExtensionsNames then return end
    local blocked
    for _, extName in ipairs(extensions.getLoadedExtensionsNames()) do
        if string.find(extName, "/", 1, true) and not serializationBlocked[extName] then
            serializationBlocked[extName] = true
            blocked = blocked or {}
            table.insert(blocked, extName)
        end
    end
    -- extensions.disableSerialization does not dedupe, hence serializationBlocked.
    if blocked then
        extensions.disableSerialization(blocked)
        log('I', 'extensionManager', 'Excluded path-named extensions from Lua reload serialization: ' .. dumps(blocked))
    end
end

local function deactivateBeamMP()
    local beammp = core_modmanager.getMods()["multiplayerbeammp"]
    if beammp then
        core_modmanager.deactivateMod("multiplayerbeammp")
    end
end

-- Configures manual-unload behavior for Overhaul's optional gameplay, career,
-- and editor extensions. BeamNG 0.39's career loader enters the world through
-- freeroam_freeroam, so that core service must remain loaded at the main menu.
local function loadExtensions()
    setExtensionUnloadMode("gameplay_events_freeroamEvents", "manual")
    setExtensionUnloadMode("gameplay_phone", "manual")
    setExtensionUnloadMode("gameplay_repo", "manual")
    setExtensionUnloadMode("gameplay_offroadRecovery", "manual")
    setExtensionUnloadMode("gameplay_rlsTaxi", "manual")
    setExtensionUnloadMode("gameplay_taxi", "manual")
    setExtensionUnloadMode("gameplay_cardGames", "manual")
    setExtensionUnloadMode("gameplay_loading", "manual")
    setExtensionUnloadMode("gameplay_physicalCargo", "manual")
    setExtensionUnloadMode("gameplay_miningHaul", "manual")
    setExtensionUnloadMode("gameplay_ambulance", "manual")
    setExtensionUnloadMode("gameplay_bus", "manual")
    setExtensionUnloadMode("gameplay_beamEats", "manual")
    setExtensionUnloadMode("gameplay_phoneCamera", "manual")
    setExtensionUnloadMode("gameplay_travelJournal", "manual")
    setExtensionUnloadMode("gameplay_trafficConfigFilter", "manual")
    setExtensionUnloadMode("gameplay_facilityWork", "manual")
    setExtensionUnloadMode("career_challengeModes", "manual")
    setExtensionUnloadMode("career_economyAdjuster", "manual")
    setExtensionUnloadMode("career_challengeSeedEncoder", "manual")
    setExtensionUnloadMode("career_modules_roadsideRepair", "manual")
    setExtensionUnloadMode("editor_freeroamEventEditor", "manual")

    setExtensionUnloadMode("dynamicRoutes", "manual")
    setExtensionUnloadMode("editor_dynamicRoutesEditor", "manual")
    setExtensionUnloadMode("vehicleMaintenance", "manual")
    setExtensionUnloadMode("overhaul_walkEnterVehicle", "manual")
    setExtensionUnloadMode("overhaul_playerVehicles", "manual")
    setExtensionUnloadMode("overhaul_groundMarkerOwnership", "manual")
    setExtensionUnloadMode("overhaul_graphpathSafety", "manual")

end

-- Unloads all career, gameplay, freeroam, and overhaul-related extensions used by the mod.
-- 
-- This forces removal of core game context, freeroam/events, gameplay modules (phone, repo, rlsTaxi, mining haul, ambulance, bus, beamEats),
-- career subsystems (career, save system, challenge modes, economy adjuster, challenge seed encoder), and overhaul modules
-- (settings, maps, clear levels, add map changes). No value is returned.
-- Remove mod-owned bindings from saved bindings so vanilla bindingsLegend does
-- not retain actions that disappear when the overhaul is deactivated.
local function removeModInputBindings()
    local modActions = {
        openPhone = true,
        rlsYankemToggle = true,
        rlsYankemReelIn = true,
        rlsYankemReelOut = true,
        rlsYankemSelect = true
    }
    pcall(function()
        if not core_input_bindings or not core_input_bindings.bindings then return end
        for _, device in ipairs(core_input_bindings.bindings) do
            if device.contents and device.contents.bindings then
                local bindings = device.contents.bindings
                for i = #bindings, 1, -1 do
                    if modActions[bindings[i].action] then
                        table.remove(bindings, i)
                    end
                end
                pcall(function()
                    core_input_bindings.saveBindingsToDisk(device.contents)
                end)
            end
        end
        -- Reload actions so the engine drops the now-unmounted phone.json
        if core_input_actions then
            extensions.reload("core_input_actions")
        end
    end)
end

local function unloadAllExtensions()
    removeModInputBindings()
    if extensions.isExtensionLoaded("rlsYankem") then
        extensions.unload("rlsYankem")
    end
    extensions.unload("core_gameContext")
    extensions.unload("gameplay_events_freeroamEvents")
    -- Travel Journal persists/cleans an active photo session through the career
    -- save system, so it must be torn down while that dependency still exists.
    extensions.unload("gameplay_travelJournal")
    extensions.unload("gameplay_trafficConfigFilter")
    extensions.unload("career_career")
    extensions.unload("career_saveSystem")
    extensions.unload("gameplay_phone")
    extensions.unload("freeroam_facilities")
    extensions.unload("gameplay_repo")
    extensions.unload("gameplay_offroadRecovery")
    extensions.unload("gameplay_rlsTaxi")
    extensions.unload("gameplay_miningHaul")
    extensions.unload("gameplay_physicalCargo")
    extensions.unload("gameplay_ambulance")
    extensions.unload("gameplay_bus")
    extensions.unload("gameplay_beamEats")
    extensions.unload("gameplay_phoneCamera")
    extensions.unload("gameplay_facilityWork")
    extensions.unload("overhaul_settings")
    extensions.unload("overhaul_maps")
    extensions.unload("overhaul_clearLevels")
    extensions.unload("overhaul_dragFreeroamBridge")
    extensions.unload("overhaul_uiRoutes")
    extensions.unload("overhaul_walkEnterVehicle")
    extensions.unload("overhaul_playerVehicles")
    extensions.unload("overhaul_groundMarkerOwnership")
    extensions.unload("overhaul_graphpathSafety")
    extensions.unload("vehicleMaintenance")
    extensions.unload("career_challengeModes")
    extensions.unload("career_economyAdjuster")
    extensions.unload("career_challengeSeedEncoder")
    extensions.unload("dynamicRoutes")
    extensions.unload("editor_dynamicRoutesEditor")
end

local function startup()
    blockUnreloadableExtensionNames()
    deactivateBeamMP()
    ensureInputActionsRegistered()

    -- Tear down the boot-time career shell before installing/reloading
    -- overrides. This avoids making the override reload pass churn the entire
    -- career dependency graph only to unload it again at the main menu.
    if not core_gamestate.state or core_gamestate.state.state ~= "career" then
        loadExtensions()
    end

    -- The override manager reloads the CEF UI. Ensure the 0.39 keyboard bridge
    -- exists before that reload can mount any text-input components.
    if not core_onScreenKeyboard then
        extensions.load("core_onScreenKeyboard")
    end

    -- Register the Lua-authoritative 0.39 routes before overrideManager reloads
    -- the CEF UI, so restored routes can always resolve on first mount.
    setExtensionUnloadMode("overhaul_uiRoutes", "manual")
    extensions.load("overhaul_uiRoutes")

    setExtensionUnloadMode("overhaul_overrideManager", "manual")
    extensions.load("overhaul_overrideManager")

    setExtensionUnloadMode("overhaul_dragFreeroamBridge", "manual")
    extensions.load("overhaul_dragFreeroamBridge")

    setExtensionUnloadMode("overhaul_settings", "manual")
    setExtensionUnloadMode("overhaul_maps", "manual")
    setExtensionUnloadMode("overhaul_clearLevels", "manual")
    extensions.load("overhaul_settings")
    extensions.load("overhaul_maps")
    extensions.load("overhaul_clearLevels")
    setExtensionUnloadMode("vehicleMaintenance", "manual")
    extensions.load("vehicleMaintenance")

    setExtensionUnloadMode("overhaul_walkEnterVehicle", "manual")
    extensions.load("overhaul_walkEnterVehicle")

    setExtensionUnloadMode("overhaul_graphpathSafety", "manual")
    extensions.load("overhaul_graphpathSafety")

    setExtensionUnloadMode("overhaul_groundMarkerOwnership", "manual")
    extensions.load("overhaul_groundMarkerOwnership")

    setExtensionUnloadMode("gameplay_travelJournal", "manual")
    extensions.load("gameplay_travelJournal")

    setExtensionUnloadMode("gameplay_trafficConfigFilter", "manual")
    extensions.load("gameplay_trafficConfigFilter")

    setExtensionUnloadMode("overhaul_playerVehicles", "manual")
    extensions.load("overhaul_playerVehicles")

    core_jobsystem.create(function(job)
        job.sleep(5)
        if not checkVersion() then
            print("Deactivating RLS Career Overhaul")
            core_modmanager.deactivateModId("RLSCO24")
        end
    end)

end

local function onModActivated(modData)
    if ourModName or ourModId then
        return
    end

    if not modData or not modData.modname then
        return
    end

    if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
        return
    end

    if not ourModName then
        ourModName = modData.modname
        if modData.modData and modData.modData.tagid then
            ourModId = modData.modData.tagid
        end
        return true
    end
end

local function onModDeactivated(modData)
    if not modData or not modData.modname then
        return
    end

    if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
        return
    end

    if (ourModName and modData.modname == ourModName) or
       (ourModId and modData.modData and modData.modData.tagid == ourModId) then
        unloadAllExtensions()
        loadManualUnloadExtensions()
    end
end

-- Swap in overrideAI without leaving the vehicle stuck in default disabled mode.
local OVERRIDE_AI_CMD = [[
extensions.load('overrideAI')
if overrideAI then
  local prevMode = ai and ai.mode
  ai = overrideAI
  if prevMode and prevMode ~= 'disabled' and ai.setMode then
    ai.setMode(prevMode)
  end
end
]]

local function queueOverrideAI(veh)
    if veh then
        veh:queueLuaCommand(OVERRIDE_AI_CMD)
    end
end

-- repo_parts.zip is an optional dependency, not part of the base overhaul.
-- Its pickup upfit relies on an implicitly loaded custom_input vehicle
-- extension and on pre-0.39 tilt/extend action names. Load our compatibility
-- bridge only on vehicles that actually contain one of those repo parts.
local REPO_TRUCK_COMPATIBILITY_CMD = [[
local hasRepoTruckParts = false
local function isRepoTruckPart(partName)
  local normalizedName = string.lower(tostring(partName or ''))
  if normalizedName == 'repo_main'
    or normalizedName == 'repo_main_long'
    or normalizedName == 'repo_parts'
    or normalizedName == 'repo_ctrl_ext'
    or normalizedName == 'repo_ctrl_int'
    or string.find(normalizedName, '/repo_main', 1, true)
    or string.find(normalizedName, '/repo_parts', 1, true)
    or string.find(normalizedName, '/repo_ctrl_ext', 1, true)
    or string.find(normalizedName, '/repo_ctrl_int', 1, true) then
    return true
  end
  return false
end

for _, partName in pairs((v.config and v.config.parts) or {}) do
  if isRepoTruckPart(partName) then
    hasRepoTruckParts = true
    break
  end
end

if not hasRepoTruckParts then
  for activePartPath in pairs((v.data and v.data.activeParts) or {}) do
    if isRepoTruckPart(activePartPath) then
      hasRepoTruckParts = true
      break
    end
  end
end

if hasRepoTruckParts then
  if not extensions.rlsRepoTruckCompatibilityVehicle then
    extensions.load('rlsRepoTruckCompatibilityVehicle')
  end
end
]]

local function queueRepoTruckCompatibility(veh)
    if veh then
        veh:queueLuaCommand(REPO_TRUCK_COMPATIBILITY_CMD)
    end
end

local function applyOverrideAI(vehId)
    local veh = vehId and be:getObjectByID(vehId)
    queueOverrideAI(veh)
end

local function applyCareerVehicleExtensions(veh)
    if not veh then return end
    veh:queueLuaCommand("extensions.load('fuelMultiplier')")
    queueOverrideAI(veh)
end

local function getTrafficRoleName(vehId)
    if not gameplay_traffic or not gameplay_traffic.getTrafficData then return nil end
    local trafficData = gameplay_traffic.getTrafficData()[vehId]
    return trafficData and trafficData.role and trafficData.role.name or nil
end

-- Inventory vehicles always get fuelMultiplier + overrideAI.
-- Benign traffic keeps stock AI (overrideAI defaulted to disabled and froze cops).
-- Suspects get overrideAI when pursuit starts via applyOverrideAI.
local function onVehicleSpawned(vehId, veh)
    if not veh then return end

    -- This queues for every spawn because career inventory registration may
    -- lag behind the spawn callback. The vehicle-side command self-filters,
    -- so non-repo vehicles pay only this one inexpensive parts-table scan.
    queueRepoTruckCompatibility(veh)

    if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
        local invId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
        if invId then
            applyCareerVehicleExtensions(veh)
            return
        end
    end

    local role = getTrafficRoleName(vehId)
    if role == 'suspect' then
        queueOverrideAI(veh)
    end
end

local function updateEditorBlocking()
    local blockedActions = {"editorToggle", "editorSafeModeToggle", "vehicleEditorToggle"}
    core_input_actionFilter.setGroup("RLS_DEACTIVATION", blockedActions)
    local cheatsEnabled = career_modules_cheats and career_modules_cheats.isCheatsMode()
    if not M.isDevKeyValid() and career_career.isActive() and not cheatsEnabled then
        core_input_actionFilter.addAction(0, "RLS_DEACTIVATION", true)
    else
        core_input_actionFilter.addAction(0, "RLS_DEACTIVATION", false)
    end
end

local function ensureFreeroamEventsLoaded()
    if not career_career or not career_career.isActive or not career_career.isActive() then
        return
    end
    if not extensions.isExtensionLoaded("gameplay_events_freContracts") then
        extensions.load("gameplay_events_freContracts")
    end
    if not extensions.isExtensionLoaded("gameplay_events_freeroamEvents") then
        extensions.load("gameplay_events_freeroamEvents")
    end
end

M.onWorldReadyState = function(state)
    if state == 2 then
        if overhaul_overrideManager and overhaul_overrideManager.ensureMarkerInteractionOverride then
            overhaul_overrideManager.ensureMarkerInteractionOverride()
        end
        updateEditorBlocking()
        ensureFreeroamEventsLoaded()
        blockUnreloadableExtensionNames()
    end
end

M.onCareerActivated = function()
    if overhaul_overrideManager and overhaul_overrideManager.ensureMarkerInteractionOverride then
        overhaul_overrideManager.ensureMarkerInteractionOverride()
    end
    ensureFreeroamEventsLoaded()
    blockUnreloadableExtensionNames()
end

M.onCheatsModeChanged = function(enabled)
    updateEditorBlocking()
end
  
M.onVehicleSpawned = onVehicleSpawned
M.onExtensionLoaded = startup
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated
M.ensureInputActionsRegistered = ensureInputActionsRegistered

M.isDevKeyValid = function()
    return devKey == FS:hashFile("devkey.txt")
end

M.getModData = function()
    return {
        name = ourModName,
        id = ourModId
    }
end

M.replayPhoneTutorial = function()
    if career_career and career_career.isActive() and
       career_modules_guide and career_modules_guide.forceStartPhoneTutorial then
        career_modules_guide.forceStartPhoneTutorial()
        return true
    end

    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Phone tutorial",
        msg = "Start or resume a career before replaying the phone tutorial."
    })
    return false
end

M.applyOverrideAI = applyOverrideAI
M.applyCareerVehicleExtensions = applyCareerVehicleExtensions
M.queueRepoTruckCompatibility = queueRepoTruckCompatibility

return M
