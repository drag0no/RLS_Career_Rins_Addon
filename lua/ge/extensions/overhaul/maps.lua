local M = {}

local compatibleMaps = {
  ["west_coast_usa"] = "West Coast USA"
}

local optionalFeatureExtensions = {
  dakar = {
    skeleton_coast = "skeletonCoast_dakar",
    pepper_valley = "Peppervalley_dakar"
  },
  roadAuthority = "skeletonCoast_roadAuthority"
}

local function getOptionalFeatureExtension(featureId)
  local feature = optionalFeatureExtensions[featureId]
  if type(feature) == "table" then
    local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
    return levelId and feature[levelId] or nil
  end
  return feature
end

local function hasOptionalFeature(featureId)
  local extensionName = getOptionalFeatureExtension(featureId)
  if not extensionName then return false end
  -- Note: indexing `extensions` goes through its __index metamethod, which tries to
  -- LOAD the extension and logs "extension unavailable" when it is missing. Use the
  -- explicit loaded-state API instead so probing an uninstalled optional feature stays silent.
  if extensions.isExtensionLoaded(extensionName) then return true end
  local extensionPath = "/lua/ge/extensions/" .. extensionName:gsub("_", "/") .. ".lua"
  return FS:fileExists(extensionPath)
end

local function retrieveCompatibleMaps()
  compatibleMaps = {
    ["west_coast_usa"] = "West Coast USA"
  }
  extensions.hook("onGetMaps")
end

local function returnCompatibleMap(maps)
  local newMapsWithOverrides = {}

  for map, mapName in pairs(maps) do
    if not compatibleMaps[map] then
      compatibleMaps[map] = mapName

      local mapOverridePath = "/overriden/levels/" .. map
      if FS:directoryExists(mapOverridePath) then
        table.insert(newMapsWithOverrides, map)
      end
    end
  end

  overhaul_overrideManager.handleMapOverrides(newMapsWithOverrides)
end

local function getOtherAvailableMaps()
    local maps = {}
    local currentMap = getCurrentLevelIdentifier()
    for map, mapName in pairs(compatibleMaps) do
      if map ~= currentMap then
        maps[map] = mapName
      end
    end
    return maps
  end
  
  local function getCompatibleMaps()
    return compatibleMaps
  end

local function getMapsExcludingWestCoast()
  local maps = {}
  for map, mapName in pairs(compatibleMaps) do
    if map ~= "west_coast_usa" then
      maps[map] = mapName
    end
  end
  return maps
end

local function onExtensionLoaded()
  retrieveCompatibleMaps()
end

M.onExtensionLoaded = onExtensionLoaded
M.onModActivated = retrieveCompatibleMaps
M.onWorldReadyState = retrieveCompatibleMaps
M.onUiReady = retrieveCompatibleMaps

M.returnCompatibleMap = returnCompatibleMap
M.getCompatibleMaps = getCompatibleMaps
M.getOtherAvailableMaps = getOtherAvailableMaps
M.getMapsExcludingWestCoast = getMapsExcludingWestCoast
M.hasOptionalFeature = hasOptionalFeature
M.getOptionalFeatureExtension = getOptionalFeatureExtension

return M
