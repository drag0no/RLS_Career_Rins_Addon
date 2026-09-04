local M = {}

local isCheatsMode = false
local infoFile = "info.json"

local saveFile = "cheats.json"
local saveData = {}

local function resolveInitialCheatsMode()
    if career_career and career_career.cheatsMode then
        return true
    end
    -- Freeroam+ start mode implies cheats even if the create flag was lost in transit.
    local pendingMode = career_career and career_career.pendingCareerStartMode
    if type(pendingMode) == "string" and string.lower(pendingMode) == "freeroam" then
        return true
    end
    local opts = career_career and career_career.startingOptions
    if type(opts) == "table" then
        if opts.cheatsMode == true then
            return true
        end
        local startMode = opts.careerStartMode or opts.startMode
        if type(startMode) == "string" and string.lower(startMode) == "freeroam" then
            return true
        end
    end
    return false
end

local function onCareerActive(active)
    if not active then return false end
    local saveSlot, savePath = career_saveSystem.getCurrentProfile()
    saveData = savePath and jsonReadFile(savePath .. "/career/rls_career/" .. saveFile) or {}
  
    if not next(saveData) then
        saveData = {
            cheatsMode = resolveInitialCheatsMode()
        }
    elseif saveData.cheatsMode ~= true and resolveInitialCheatsMode() then
        -- New Freeroam+ create: seed file may have been written false before
        -- career_career.cheatsMode was visible on the live extension table.
        saveData.cheatsMode = true
    end
    
    if saveData.cheatsMode == nil then
        saveData.cheatsMode = false
    end
    
    isCheatsMode = saveData.cheatsMode == true
    extensions.hook("onCheatsModeChanged", isCheatsMode)
end

local function onSaveCurrentProfile(currentSavePath)
    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/rls_career/" .. saveFile, saveData, true)
end

M.enableCheatsMode = function(enabled)
    if enabled and not isCheatsMode then
        isCheatsMode = true
        saveData.cheatsMode = true
        extensions.hook("onCheatsModeChanged", isCheatsMode)
    end
end

M.isCheatsMode = function()
    return isCheatsMode or false
end

-- Insert recover_vehicle is only unblocked in Freeroam+/cheats. Stock recover
-- resets body meshes but RLS tires/maintenance reassert afterward — clear them.
local function onStopRecovering()
    if not isCheatsMode then
        return
    end

    local veh = getPlayerVehicle(0)
    if not veh then
        return
    end

    local vehId = veh:getID()
    local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and
                            career_modules_inventory.getInventoryIdFromVehicleId(vehId) or nil

    if inventoryId and career_modules_tireSystem and career_modules_tireSystem.forceFreshForVehicle then
        career_modules_tireSystem.forceFreshForVehicle(inventoryId)
    end
    if inventoryId and vehicleMaintenance and vehicleMaintenance.resetAllCategories then
        vehicleMaintenance.resetAllCategories(inventoryId)
    end

    veh:queueLuaCommand([[
      if maintenanceManager then
        maintenanceManager.debugResetCategory('engine')
        maintenanceManager.debugResetCategory('radiator')
        maintenanceManager.debugResetCategory('transmission')
      end
      obj:requestReset(RESET_PHYSICS)
      if rlsTireProvider and rlsTireProvider.applyFreshAndInflate then
        rlsTireProvider.applyFreshAndInflate()
      end
    ]])
end

M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onStopRecovering = onStopRecovering

return M
