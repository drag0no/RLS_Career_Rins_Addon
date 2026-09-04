local M = {}

M.dependencies = {"career_career", "career_saveSystem", "career_modules_dynamicWeather"}

local saveFile = "time.json"

local originComputerId
local isSleeping = false
local sleepTime = 0
local careerActive = false
local play
local usedDynamicSleep = false

local function dynamicWeatherControlsClock()
    if not career_modules_dynamicWeather or not career_modules_dynamicWeather.sleepTo then return false end
    if career_modules_dynamicWeather.isExternalOverrideActive and career_modules_dynamicWeather.isExternalOverrideActive() then return false end
    return true
end

-- Rolling TOD is the overhaul default; players can disable it from the sleep menu.
local DEFAULT_PLAY = true

local function isPlayEnabled()
    if core_environment and core_environment.getTimeOfDay then
        local tod = core_environment.getTimeOfDay()
        if tod and tod.play ~= nil then
            return tod.play and true or false
        end
    end
    if scenetree and scenetree.tod then
        -- BeamNG may expose cycle as play and/or animate.
        if scenetree.tod.play ~= nil then
            return scenetree.tod.play and true or false
        end
        if scenetree.tod.animate ~= nil then
            return scenetree.tod.animate and true or false
        end
    end
    return DEFAULT_PLAY
end

local function getTodTime()
    if core_environment and core_environment.getTimeOfDay then
        local tod = core_environment.getTimeOfDay()
        if tod and tod.time ~= nil then
            return tod.time
        end
    end
    if scenetree and scenetree.tod and scenetree.tod.time ~= nil then
        return scenetree.tod.time
    end
    return 0
end

local function applyTod(time, playValue)
    local playBool = nil
    if playValue ~= nil then
        playBool = playValue and true or false
    end

    -- Always write the SimObject directly. core_environment.setTimeOfDay can no-op when
    -- enableChanges is false (e.g. cargo big-map lock), which made the sleep toggle appear
    -- to do nothing.
    if scenetree and scenetree.tod then
        if time ~= nil then scenetree.tod.time = time end
        if playBool ~= nil then
            scenetree.tod.play = playBool
            if scenetree.tod.animate ~= nil then
                scenetree.tod.animate = playBool
            end
        end
    end

    if core_environment and core_environment.setTimeOfDay then
        local tod = core_environment.getTimeOfDay() or {}
        if time ~= nil then tod.time = time end
        if playBool ~= nil then tod.play = playBool end
        pcall(core_environment.setTimeOfDay, tod)
    end
end

local function saveTimeData(currentSavePath)
    if career_modules_dynamicWeather and career_modules_dynamicWeather.getClockState then
        return
    end
    if not currentSavePath then
        local slot, path = career_saveSystem.getCurrentProfile()
        currentSavePath = path
        if not currentSavePath then return end
    end
    if not (scenetree and scenetree.tod) and not (core_environment and core_environment.getTimeOfDay) then
        return
    end

    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    local data = {
        time = getTodTime(),
        play = isPlayEnabled()
    }
    career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, data, true)
end

local function loadTimeData()
    if career_modules_dynamicWeather and career_modules_dynamicWeather.getClockState then
        return
    end
    if not career_career.isActive() then return end
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    if not currentSavePath then return end
    
    local filePath = currentSavePath .. "/career/rls_career/" .. saveFile
    local data = jsonReadFile(filePath)
    
    if data and data.time ~= nil then
        local playValue = DEFAULT_PLAY
        if data.play ~= nil then
            playValue = data.play and true or false
        end
        applyTod(data.time, playValue)
    else
        -- No save yet: enable rolling TOD by default.
        applyTod(nil, DEFAULT_PLAY)
    end
end

local function getDayNightCycle()
    if career_modules_dynamicWeather and career_modules_dynamicWeather.getDayNightCycle then
        return career_modules_dynamicWeather.getDayNightCycle()
    end
    return {play = isPlayEnabled(), time = getTodTime()}
end

local function onCareerActive(active)
    careerActive = active
end

local function onWorldReadyState(state)
    if state == 2 and careerActive then
        loadTimeData()
    end
end

local function onSaveCurrentProfile(currentSavePath)
    saveTimeData(currentSavePath)
end

local function openMenuFromComputer(computerId)
    originComputerId = computerId  -- Store the computer ID
    print("Open sleep menu from computer: " .. computerId)
    extensions.ui_router.navigate('sleep-menu')
end

local function closeMenu()
    if originComputerId then
        local computer = freeroam_facilities.getFacility("computer", originComputerId)
        career_modules_computer.openMenu(computer)
    else
        career_career.closeAllMenus()
    end
end

local function closeAllMenus()
    career_career.closeAllMenus()
end

local function toggleDayNightCycle(toggle)
    if career_modules_dynamicWeather and career_modules_dynamicWeather.toggleDayNightCycle then
        career_modules_dynamicWeather.toggleDayNightCycle(toggle)
        return
    end
    applyTod(nil, toggle and true or false)
    -- Persist immediately so leaving the menu without sleeping keeps the preference.
    saveTimeData()
end

local function onComputerAddFunctions(menuData, computerFunctions)
    if not menuData.computerFacility.functions["sleep"] then
        return
    end

    local computerFunctionData = {
        id = "sleep",
        label = "Sleep",
        callback = function()
            openMenuFromComputer(menuData.computerFacility.id)
        end,
        order = 20
    }

    computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local function onScreenFadeState(state)
    if state == 1 and isSleeping then
        usedDynamicSleep = dynamicWeatherControlsClock()
        if usedDynamicSleep then
            usedDynamicSleep = career_modules_dynamicWeather.sleepTo(sleepTime) == true
        end
        if not usedDynamicSleep then
            play = isPlayEnabled()
            applyTod(sleepTime, true)
        end
        ui_fadeScreen.stop(0.5)

        local closestGarage = career_modules_inventory.getClosestGarage()
        local pos, _ = freeroam_facilities.getGaragePosRot(closestGarage)
        career_modules_playerDriving.showPosition(pos)
    elseif state == 3 and isSleeping then
        if not usedDynamicSleep then
            -- Restore the player's cycle preference (default rolling if unknown).
            applyTod(nil, play == nil and DEFAULT_PLAY or play)
        end
        usedDynamicSleep = false
        isSleeping = false
        saveTimeData()
    end
end


local function sleep(time)
    isSleeping = true
    sleepTime = time
    ui_fadeScreen.start(0.5)
end

M.openMenuFromComputer = openMenuFromComputer
M.onComputerAddFunctions = onComputerAddFunctions

M.sleep = sleep
M.getDayNightCycle = getDayNightCycle
M.toggleDayNightCycle = toggleDayNightCycle
M.closeMenu = closeMenu
M.closeAllMenus = closeAllMenus

M.onScreenFadeState = onScreenFadeState
M.onCareerActive = onCareerActive
M.onWorldReadyState = onWorldReadyState
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
