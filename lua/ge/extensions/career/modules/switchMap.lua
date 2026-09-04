local M = {}


M.dependencies = {'career_career'}

local function switchMap(levelName)
    local currentLevel = getCurrentLevelIdentifier()
    if currentLevel == levelName then return end
    local accepted, reason = career_career.switchCareerLevel(levelName)
    if accepted then
        gameplay_parking.resetAll()
        return true
    end
    guihooks.trigger("toastrMsg", {
        type = "error",
        title = "Map travel unavailable",
        msg = tostring(reason or "The destination could not be loaded."),
    })
    return false, reason
end

local function cancelSwitch()
    simTimeAuthority.pause(false)
    if career_career and career_career.closeAllMenus then
        career_career.closeAllMenus()
    else
        extensions.ui_router.navigate('play')
    end
end

local function onRouteLeave()
    -- Entering the switcher pauses simulation. Always restore it when any
    -- route transition leaves the screen, including BACK/Escape.
    simTimeAuthority.pause(false)
end

local function isOverhaulAddonActive(levelName)
    local mods = core_modmanager.getMods()
    for modName, modData in pairs(mods) do
        local OverhaulAddon = "rls_career_overhaul_" .. levelName
        if modName:lower():find(OverhaulAddon) and modData.active then
            return true
        end
    end
    return false
end

local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID then
        return
    end
    local isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
    if career_career.isActive() and not isWalking and not career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) then
        return
    end
    if data.event ~= "exit" then
        return
    end
    local triggerName = data.triggerName
    
    if triggerName:match("^switchTo_") or triggerName:match("^switchMaps") then
        simTimeAuthority.pause(true)
        extensions.ui_router.navigate('level-switch')
        return
    end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    if not (career_career and career_career.isActive()) then return end
    -- Find any object with switchTo_ prefix by checking available maps
    local switchToObj = nil
    
    -- Look for any switchTo_ object from the available maps
    switchToObj = scenetree.findObject("switchMaps")
    if not switchToObj then
        for level, levelName in pairs(overhaul_maps.getOtherAvailableMaps()) do
            local obj = scenetree.findObject("switchTo_" .. level)
            if obj then
                switchToObj = obj
                break
            end
        end
    end
    
    if not switchToObj then return end
    
    local pos = switchToObj:getPosition()
    if not pos then return end
    
    local description = "Available maps to switch to:\n"
    local mapRows = {}
    for level, levelName in pairs(overhaul_maps.getOtherAvailableMaps(levelIdentifier)) do
        mapRows[#mapRows + 1] = levelName
    end
    table.sort(mapRows, function(a, b) return string.lower(a) < string.lower(b) end)
    local mapCount = #mapRows
    for _, levelName in ipairs(mapRows) do
        description = description .. "• " .. levelName .. "\n"
    end
    
    if mapCount > 0 then
        local preview = "/levels/" .. levelIdentifier .. "/facilities/switchMap.jpg"
        
        local poi = {
            id = "map_switcher",
            data = {
                type = "travel",
                facility = {}
            },
            markerInfo = {
                bigmapMarker = {
                    pos = pos,
                    icon = "poi_fasttravel_round_orange_green",
                    name = "Map Switcher",
                    description = description,
                    previews = {preview},
                    thumbnail = preview,
                    cardIcon = "fastTravel",
                }
            }
        }
        
        table.insert(elements, poi)
    end
end

M.switchMap = switchMap
M.cancelSwitch = cancelSwitch
M.onRouteLeave = onRouteLeave
M.onBeamNGTrigger = onBeamNGTrigger

return M
