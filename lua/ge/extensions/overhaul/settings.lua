local M = {}

local settingsRoot = 'settings/RLS/'
local settingsFile = 'careerOverhaul.json'
local settingsFilePath = settingsRoot .. settingsFile

local settings = {
    mapDevMode = false,
    noParkedMode = false,
    forcePhoneTutorial = false,
    racingTeamDevConsole = false,
    realisticVehicleEntry = true,
    realisticWalkingCamera = true,
    freeroamRaceHudLayout = { x = 12, y = 12, width = 340 }
}

local function saveSettings()
    if not FS:directoryExists(settingsRoot) then
        FS:directoryCreate(settingsRoot)
    end
    
    if jsonWriteFile(settingsFilePath, settings, true) then
        log('I', 'rlsSettings', 'Settings saved to: ' .. settingsFilePath)
        return true
    else
        log('E', 'rlsSettings', 'Failed to save settings to: ' .. settingsFilePath)
        return false
    end
end

local function getSetting(key)
    return settings[key]
end

local function getSettings()
    return deepcopy(settings)
end

local function applySettingSideEffects(key)
    if key == 'racingTeamDevConsole' then
        local rt = rawget(_G, 'career_modules_business_racingTeam')
        if rt and rt.refreshDevConsoleTab then
            pcall(rt.refreshDevConsoleTab)
        end
    end
end

local function setSetting(key, value)
    if settings[key] == nil then
        log('W', 'rlsSettings', 'Ignoring unknown or retired setting: ' .. tostring(key))
        return false
    end

    if settings[key] ~= value then
        local previousValue = settings[key]
        settings[key] = value
        if not saveSettings() then
            settings[key] = previousValue
            return false
        end
        log('I', 'rlsSettings', 'Setting ' .. key .. ' set to: ' .. tostring(value))
        applySettingSideEffects(key)
    end
    return true
end

local function setSettings(values)
    if type(values) ~= 'table' then
        return false
    end

    local previousValues = {}
    local changedKeys = {}

    for key, value in pairs(values) do
        if settings[key] == nil then
            log('W', 'rlsSettings', 'Ignoring unknown or retired setting: ' .. tostring(key))
        elseif type(value) ~= type(settings[key]) then
            log('W', 'rlsSettings', 'Ignoring invalid value for setting: ' .. tostring(key))
        elseif settings[key] ~= value then
            previousValues[key] = settings[key]
            settings[key] = value
            table.insert(changedKeys, key)
        end
    end

    if #changedKeys == 0 then
        return true
    end

    if not saveSettings() then
        for key, value in pairs(previousValues) do
            settings[key] = value
        end
        return false
    end

    for _, key in ipairs(changedKeys) do
        log('I', 'rlsSettings', 'Setting ' .. key .. ' set to: ' .. tostring(settings[key]))
        applySettingSideEffects(key)
    end

    return true
end

local function loadSettings()
    local data = jsonReadFile(settingsFilePath)
    if data then
        local retiredNoPoliceMode = data.noPoliceMode ~= nil
        local migrateWalkingCameraBob = data.walkingCameraBob ~= nil and data.realisticWalkingCamera == nil
        for k, v in pairs(data) do
            if settings[k] ~= nil then
                settings[k] = v
            end
        end
        if migrateWalkingCameraBob and type(data.walkingCameraBob) == 'boolean' then
            settings.realisticWalkingCamera = data.walkingCameraBob
        end
        log('I', 'rlsSettings', 'Settings loaded from: ' .. settingsFilePath)
        if retiredNoPoliceMode or migrateWalkingCameraBob then
            if retiredNoPoliceMode then
                log('I', 'rlsSettings', 'Removed retired noPoliceMode setting; police preference is now stored per career save')
            end
            if migrateWalkingCameraBob then
                log('I', 'rlsSettings', 'Migrated walkingCameraBob to realisticWalkingCamera')
            end
            saveSettings()
        end
    else
        log('I', 'rlsSettings', 'No settings file found, using defaults')
        saveSettings()
    end
end

local function onExtensionLoaded()
    loadSettings()
end

M.getSetting = getSetting
M.getSettings = getSettings
M.setSetting = setSetting
M.setSettings = setSettings
M.loadSettings = loadSettings
M.onExtensionLoaded = onExtensionLoaded

return M
