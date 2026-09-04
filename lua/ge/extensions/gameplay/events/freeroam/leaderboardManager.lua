local M = {}

local leaderboardFile = "career/rls_career/races_leaderboard.json"
local leaderboard = {}

local level

local function loadLeaderboard()
    if not career_career or not career_career.isActive() then
        return
    end
    local saveSlot, savePath = career_saveSystem.getCurrentProfile()
    local file = savePath .. '/' .. leaderboardFile
    leaderboard = jsonReadFile(file) or {}
    if type(leaderboard) ~= "table" then
        leaderboard = {}
    end
end

local function saveLeaderboard(currentSavePath)
    if not leaderboard then
        leaderboard = {}
    end
    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/" .. leaderboardFile, leaderboard, true)
end

local function isBestTime(entry)
    level = getCurrentLevelIdentifier()
    if not leaderboard then
        leaderboard = {}
    end
    local leaderboardEntry = leaderboard[level] or {}
    if not leaderboardEntry then
        return true
    end

    leaderboardEntry = leaderboardEntry[tostring(entry.inventoryId)] or {}
    if not leaderboardEntry then
        return true
    end

    leaderboardEntry = leaderboardEntry[entry.raceLabel] or {}
    if not leaderboardEntry then
        return true
    end

    if entry.driftScore and entry.driftScore > 0 then
        if not leaderboardEntry.driftScore then
            return true
        end
        return entry.driftScore > leaderboardEntry.driftScore
    end

    -- Handle top speed races
    if entry.topSpeed and entry.topSpeed > 0 then
        local utils = require('gameplay/events/freeroam/utils')
        local races = utils.loadRaceData()
        local race = races[entry.raceName]
        
        if race and race.topSpeed then
            if not leaderboardEntry.topSpeed then
                return true
            end
            return entry.topSpeed > leaderboardEntry.topSpeed
        end
    end

    -- Handle damage-based races
    if entry.damageFactor and entry.damageFactor > 0 then
        -- If this is a damage-based race, compare based on the hybrid system
        local utils = require('gameplay/events/freeroam/utils')
        
        -- Get the race data to know the goal time and reward
        local races = utils.loadRaceData()
        local race = races[entry.raceName]
        if not race then
            return true
        end
        
        local goalTime = race.bestTime
        local baseReward = race.reward
        
        -- Handle alt route and hotlap variations
        if entry.isAltRoute and race.altRoute then
            goalTime = race.altRoute.bestTime
            baseReward = race.altRoute.reward
        end
        if entry.isHotlap and race.hotlap then
            goalTime = race.hotlap
        end
        
        -- Calculate current entry's hybrid score
        local currentScore = utils.hybridRaceReward(goalTime, baseReward, entry.time, entry.damageFactor, entry.damagePercentage)
        
        -- Calculate existing leaderboard entry's hybrid score if it exists
        if not leaderboardEntry.time then
            return true
        end
        
        local existingDamagePercentage = leaderboardEntry.damagePercentage or 0
        local existingScore = utils.hybridRaceReward(goalTime, baseReward, leaderboardEntry.time, entry.damageFactor, existingDamagePercentage)
        
        return currentScore > existingScore
    end

    -- Default time-based comparison
    if not leaderboardEntry.time then
        return true
    end
    return entry.time < leaderboardEntry.time
end


local function addLeaderboardEntry(entry)
    level = getCurrentLevelIdentifier()

    if career_career and career_career.isActive() then
        career_modules_inventory.saveFRETimeToVehicle(entry.raceLabel, entry.inventoryId, entry.time, entry.driftScore)
    end
    
    if not gameplay_events_freeroam_dataCollection then
        extensions.load('gameplay_events_freeroam_dataCollection')
    end
    gameplay_events_freeroam_dataCollection.collectDataFromEntry(entry)
    
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[level] then 
        leaderboard[level] = {}
    end
    if not leaderboard[level][tostring(entry.inventoryId)] then
        leaderboard[level][tostring(entry.inventoryId)] = {}
    end
    local leaderboardEntry = leaderboard[level][tostring(entry.inventoryId)]
    
    local isBest = isBestTime(entry)
    
    if isBest then
        local raceLabel = entry.raceLabel
        leaderboardEntry[raceLabel] = leaderboardEntry[raceLabel] or {}
        leaderboardEntry[raceLabel].time = entry.time
        leaderboardEntry[raceLabel].splitTimes = entry.splitTimes
        leaderboardEntry[raceLabel].driftScore = entry.driftScore
        leaderboardEntry[raceLabel].damagePercentage = entry.damagePercentage
        leaderboardEntry[raceLabel].damageFactor = entry.damageFactor
        leaderboardEntry[raceLabel].topSpeed = entry.topSpeed
        leaderboardEntry[raceLabel].reward = entry.reward
        return true
    end
    return false
end

local function updateDemoDerbyStats(inventoryId, raceLabel, result)
    if not inventoryId or not raceLabel then
        return nil
    end

    level = getCurrentLevelIdentifier()
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[level] then
        leaderboard[level] = {}
    end

    local invKey = tostring(inventoryId)
    if not leaderboard[level][invKey] then
        leaderboard[level][invKey] = {}
    end

    local entry = leaderboard[level][invKey][raceLabel] or {}
    leaderboard[level][invKey][raceLabel] = entry

    local placeNum = tonumber(result and result.placement)
    if not placeNum or placeNum ~= placeNum or placeNum == math.huge or placeNum == -math.huge or placeNum < 1 then
        return nil
    end
    local place = math.floor(placeNum)
    local survivalTime = math.max(0, tonumber(result and result.survivalTime) or 0)
    local fastestElimTime = tonumber(result and result.fastestEliminationTime)

    local runs = math.max(0, math.floor(tonumber(entry.demoRuns) or 0)) + 1
    local wins = math.max(0, math.floor(tonumber(entry.demoWins) or 0))
    local podiums = math.max(0, math.floor(tonumber(entry.demoPodiums) or 0))
    local placementSum = math.max(0, tonumber(entry.demoPlacementSum) or 0)
    local totalSurvivalTime = math.max(0, tonumber(entry.demoTotalSurvivalTime) or 0)

    if place == 1 then
        wins = wins + 1
    end
    if place <= 3 then
        podiums = podiums + 1
    end

    placementSum = placementSum + place
    totalSurvivalTime = totalSurvivalTime + survivalTime

    entry.demoRuns = runs
    entry.demoWins = wins
    entry.demoPodiums = podiums
    entry.demoPlacementSum = placementSum
    entry.demoAveragePlacement = placementSum / runs
    entry.demoPodiumRate = podiums / runs
    entry.demoAverageSurvivalTime = totalSurvivalTime / runs
    entry.demoTotalSurvivalTime = totalSurvivalTime
    entry.demoBestPlacement = math.min(math.max(1, math.floor(tonumber(entry.demoBestPlacement) or place)), place)
    entry.demoLongestSurvivalTime = math.max(tonumber(entry.demoLongestSurvivalTime) or 0, survivalTime)

    if fastestElimTime and fastestElimTime > 0 then
        local prevFast = tonumber(entry.demoFastestEliminationTime)
        if not prevFast or prevFast <= 0 then
            entry.demoFastestEliminationTime = fastestElimTime
        else
            entry.demoFastestEliminationTime = math.min(prevFast, fastestElimTime)
        end
    end

    return entry
end

local function clearLeaderboardForVehicle(inventoryId)
    level = getCurrentLevelIdentifier()
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[level] or not leaderboard[level][tostring(inventoryId)] then
        return
    end
    leaderboard[level][tostring(inventoryId)] = nil
end

local function clearLeaderboardInventoriesBatchAtAllLevels(inventoryIds)
    if type(inventoryIds) ~= "table" or #inventoryIds == 0 then
        return
    end
    if not career_career or not career_career.isActive() then
        return
    end
    local _, savePath = career_saveSystem.getCurrentProfile()
    if not savePath or savePath == "" then
        return
    end
    loadLeaderboard()
    if not leaderboard then
        leaderboard = {}
    end
    local removed = false
    for _, inventoryId in ipairs(inventoryIds) do
        local inv = tostring(inventoryId or "")
        if inv ~= "" then
            for _, vehMap in pairs(leaderboard) do
                if type(vehMap) == "table" and vehMap[inv] ~= nil then
                    vehMap[inv] = nil
                    removed = true
                end
            end
        end
    end
    if removed then
        saveLeaderboard(savePath)
    end
end

local function clearLeaderboardInventoryAtAllLevels(inventoryId)
    if not inventoryId or inventoryId == "" then
        return
    end
    clearLeaderboardInventoriesBatchAtAllLevels({ inventoryId })
end

local function onExtensionLoaded()
    level = getCurrentLevelIdentifier()
    if level then
        loadLeaderboard()
    end
end

local function onWorldReadyState(state)
    if state == 2 then
        level = getCurrentLevelIdentifier()
        loadLeaderboard()
    end
end

local function onSaveCurrentProfile(currentSavePath)
    saveLeaderboard(currentSavePath)
end

local function getLeaderboardEntryAtLevel(levelId, inventoryId, raceLabel)
    if not levelId or levelId == "" or not inventoryId or not raceLabel then
        return {}
    end
    if not leaderboard then
        leaderboard = {}
    end
    if not leaderboard[levelId] or not leaderboard[levelId][tostring(inventoryId)] then
        return {}
    end
    return leaderboard[levelId][tostring(inventoryId)][raceLabel] or {}
end

local function getLeaderboardEntry(inventoryId, raceLabel)
    level = getCurrentLevelIdentifier()
    return getLeaderboardEntryAtLevel(level, inventoryId, raceLabel)
end

local function getLeaderboardEntriesForVehicle(inventoryId)
    level = getCurrentLevelIdentifier()
    if not leaderboard or not level or not leaderboard[level] or not leaderboard[level][tostring(inventoryId)] then
        return {}
    end
    local vehicleEntries = leaderboard[level][tostring(inventoryId)]
    local list = {}
    for raceLabel, entry in pairs(vehicleEntries) do
        if type(entry) == "table" and (entry.time or entry.driftScore or entry.topSpeed or (tonumber(entry.demoRuns) or 0) > 0) then
            list[#list + 1] = {
                raceLabel = raceLabel,
                time = entry.time,
                driftScore = entry.driftScore,
                damagePercentage = entry.damagePercentage,
                topSpeed = entry.topSpeed,
                reward = entry.reward,
                demoRuns = entry.demoRuns,
                demoWins = entry.demoWins,
                demoPodiums = entry.demoPodiums,
                demoAveragePlacement = entry.demoAveragePlacement,
                demoPodiumRate = entry.demoPodiumRate,
                demoFastestEliminationTime = entry.demoFastestEliminationTime,
                demoAverageSurvivalTime = entry.demoAverageSurvivalTime,
                demoLongestSurvivalTime = entry.demoLongestSurvivalTime
            }
        end
    end
    return list
end

local function onCareerActive(active)
    if active then
        loadLeaderboard()
    else
        leaderboard = {}
    end
end

M.onVehicleRemoved = clearLeaderboardForVehicle
M.clearLeaderboardForVehicle = clearLeaderboardForVehicle
M.clearLeaderboardInventoryAtAllLevels = clearLeaderboardInventoryAtAllLevels
M.clearLeaderboardInventoriesBatchAtAllLevels = clearLeaderboardInventoriesBatchAtAllLevels
M.onCareerActive = onCareerActive

M.onExtensionLoaded = onExtensionLoaded
M.onWorldReadyState = onWorldReadyState

M.onSaveCurrentProfile = onSaveCurrentProfile
M.addLeaderboardEntry = addLeaderboardEntry
M.updateDemoDerbyStats = updateDemoDerbyStats

M.isBestTime = isBestTime
M.getLeaderboardEntry = getLeaderboardEntry
M.getLeaderboardEntryAtLevel = getLeaderboardEntryAtLevel
M.getLeaderboardEntriesForVehicle = getLeaderboardEntriesForVehicle

return M