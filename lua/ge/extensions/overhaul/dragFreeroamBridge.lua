local M = {}

M.dependencies = {"gameplay_drag_core", "gameplay_drag_saveSystem"}

local freeroamEvents = require("gameplay/events/freeroamEvents")
local freeroamUtils = require("gameplay/events/freeroam/utils")
local logTag = "dragFreeroamBridge"
local legacyTypeWrapped = false

-- BeamNG 0.39 removed dragPracticeRace / headsUpDrag; only headsUpRace and
-- bracketRace remain. Map packs (AR, JRI, etc.) still ship the old type.
local LEGACY_DRAG_TYPES = {
  dragPracticeRace = true,
  headsUpDrag = true,
}

-- 0.38 tree light object names (still used by custom map-pack strips).
local LEGACY_LIGHT_NAME_PATTERNS = {
  prestage = {"Prestagelight_%d", "prestagelight_%d"},
  stage = {"Stagelight_%d", "stagelight_%d"},
  winTimeboard = {"WinLight_Timeboard_%d", "winTimeboard_%d"},
  winDriver = {"WinLight_Driver_%d", "winDriver_%d"},
  amber1 = {"Amberlight1_%d", "amberlight1_%d"},
  amber2 = {"Amberlight2_%d", "amberlight2_%d"},
  amber3 = {"Amberlight3_%d", "amberlight3_%d"},
  green = {"Greenlight_%d", "greenlight_%d"},
  red = {"Redlight_%d", "redlight_%d"},
  blue = {"BlueLight", "blueLight"},
}

local function findSceneObjectByPatterns(patterns, laneIndex)
  if not patterns then return nil end
  for _, pattern in ipairs(patterns) do
    local name = laneIndex and string.format(pattern, laneIndex) or pattern
    local obj = scenetree.findObject(name)
    if obj then return obj end
  end
  return nil
end

local function asVec3(v)
  if not v then return nil end
  if v.squaredLength then return v end
  if v.x ~= nil and v.y ~= nil and v.z ~= nil then
    return vec3(v.x, v.y, v.z)
  end
  return nil
end

local function asQuat(v)
  if not v or v.w == nil or v.x == nil or v.y == nil or v.z == nil then
    return nil
  end
  -- Already a live quat (has metatable / is userdata); plain JSON tables need wrapping.
  if type(v) ~= "table" or getmetatable(v) ~= nil then
    return v
  end
  return quat(v.x, v.y, v.z, v.w)
end

local function zoneFromBoundaryTransform(boundary, name)
  local t = boundary and boundary.transform
  if not t then return nil end

  local pos = asVec3(t.position)
  local rot = asQuat(t.rotation)
  local scl = asVec3(t.scale)
  if not pos or not rot or not scl then
    return nil
  end

  -- Match 0.38 drag utils: OBB half-axes are rot * scale components.
  local x = rot * vec3(scl.x, 0, 0)
  local y = rot * vec3(0, scl.y, 0)
  local corners = {
    pos - x - y,
    pos + x - y,
    pos + x + y,
    pos - x + y,
  }

  local ZoneClass = require("/lua/ge/extensions/gameplay/sites/zone")
  local zone = ZoneClass(nil, name or "legacyLaneBoundary")
  for _, corner in ipairs(corners) do
    zone:addVertex(corner)
  end
  return zone
end

local function ensureLegacyLaneZones(dragData)
  if not dragData or not dragData.strip or not dragData.strip.lanes then
    return false
  end

  local built = false
  for i, lane in ipairs(dragData.strip.lanes) do
    if (not lane.zone or not lane.zone.containsPoint2D) and lane.boundary then
      local zone = zoneFromBoundaryTransform(lane.boundary, (lane.id or "lane") .. "_zone")
      if zone then
        lane.zone = zone
        built = true
      end
    end
  end
  return built
end

local function bindLegacyTreeLights(dragData)
  if not dragData or not dragData.strip or not dragData.strip.lanes then
    return false
  end

  local treeLights = dragData.strip.treeLights
  if not treeLights then
    treeLights = {}
    dragData.strip.treeLights = treeLights
  end

  local rebound = false
  for laneIndex = 1, #dragData.strip.lanes do
    local laneTree = treeLights[laneIndex]
    if not laneTree then
      laneTree = {
        stageLights = {
          prestageLight = {anim = "prestage", isOn = false},
          stageLight = {anim = "prestage", isOn = false},
          winnerLight = {anim = "prestage", isOn = false},
          driverLight = {anim = "prestage", isOn = false},
        },
        countDownLights = {
          amberLight1 = {anim = "tree", isOn = false},
          amberLight2 = {anim = "tree", isOn = false},
          amberLight3 = {anim = "tree", isOn = false},
          greenLight = {anim = "tree", isOn = false},
          redLight = {anim = "tree", isOn = false},
        },
        globalLights = {},
        timers = {dialOffset = 0, laneTimer = 0, laneTimerFlag = false},
      }
      treeLights[laneIndex] = laneTree
    end

    local stockPre = laneTree.stageLights and laneTree.stageLights.prestageLight and laneTree.stageLights.prestageLight.obj
    if not stockPre then
      laneTree.stageLights.prestageLight.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.prestage, laneIndex)
      laneTree.stageLights.stageLight.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.stage, laneIndex)
      laneTree.stageLights.winnerLight.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.winTimeboard, laneIndex)
      laneTree.stageLights.driverLight.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.winDriver, laneIndex)
      laneTree.countDownLights.amberLight1.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.amber1, laneIndex)
      laneTree.countDownLights.amberLight2.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.amber2, laneIndex)
      laneTree.countDownLights.amberLight3.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.amber3, laneIndex)
      laneTree.countDownLights.greenLight.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.green, laneIndex)
      laneTree.countDownLights.redLight.obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.red, laneIndex)
      rebound = true
    end
  end

  if treeLights[1] then
    treeLights[1].globalLights = treeLights[1].globalLights or {}
    local blue = treeLights[1].globalLights.blueLight
    if not blue or not blue.obj then
      treeLights[1].globalLights.blueLight = {
        obj = findSceneObjectByPatterns(LEGACY_LIGHT_NAME_PATTERNS.blue),
        anim = "prestage",
        isOn = false,
      }
      rebound = true
    end
  end

  return rebound
end

local function normalizeLegacyDragData(dragData)
  if not dragData then return dragData end

  local dragType = dragData.dragType
  if dragType and LEGACY_DRAG_TYPES[dragType] then
    log("I", logTag, string.format('Remapping legacy dragType "%s" -> headsUpRace', tostring(dragType)))
    dragData.dragType = "headsUpRace"
  end

  -- Freeroam practice strips in map packs ship Pro (.400); overhaul freeroam
  -- uses Sportsman (.500).
  if dragData.context == "freeroam" then
    if not dragData.prefabs then dragData.prefabs = {} end
    if not dragData.prefabs.christmasTree then dragData.prefabs.christmasTree = {} end
    if dragData.prefabs.christmasTree.treeType ~= ".500" then
      log("I", logTag, string.format(
        'Forcing freeroam treeType "%s" -> .500 (Sportsman)',
        tostring(dragData.prefabs.christmasTree.treeType)
      ))
      dragData.prefabs.christmasTree.treeType = ".500"
    end
  end

  if ensureLegacyLaneZones(dragData) then
    log("I", logTag, "Synthesized lane zones from legacy boundary transforms")
  end

  return dragData
end

local function wrapLegacyDragTypeRemap()
  if legacyTypeWrapped then return true end

  if not gameplay_drag_saveSystem then
    extensions.load("gameplay_drag_saveSystem")
  end
  if not gameplay_drag_core then
    extensions.load("gameplay_drag_core")
  end

  local wrapped = false

  if gameplay_drag_saveSystem and type(gameplay_drag_saveSystem.loadDragStripData) == "function" then
    local originalLoad = gameplay_drag_saveSystem.loadDragStripData
    gameplay_drag_saveSystem.loadDragStripData = function(filepath)
      return normalizeLegacyDragData(originalLoad(filepath))
    end
    wrapped = true
  end

  if gameplay_drag_core and type(gameplay_drag_core.setDragRaceData) == "function" then
    local originalSet = gameplay_drag_core.setDragRaceData
    gameplay_drag_core.setDragRaceData = function(data)
      return originalSet(normalizeLegacyDragData(data))
    end
    wrapped = true
  end

  if gameplay_drag_core and type(gameplay_drag_core.loadDragStripData) == "function" then
    local originalCoreLoad = gameplay_drag_core.loadDragStripData
    gameplay_drag_core.loadDragStripData = function(filepath)
      return normalizeLegacyDragData(originalCoreLoad(filepath))
    end
    wrapped = true
  end

  if wrapped then
    legacyTypeWrapped = true
    log("I", logTag, "Installed legacy drag strip remappers (type, zones, tree lights)")
  else
    log("W", logTag, "Could not install legacy drag remappers yet (drag extensions missing)")
  end
  return wrapped
end

local function isFreeroamDrag()
  if not gameplay_drag_core or not gameplay_drag_core.getGameplayContext then
    return false
  end
  return gameplay_drag_core.getGameplayContext() == "freeroam"
end

local function getPlayableRacer(vehId)
  local dragData = gameplay_drag_core and gameplay_drag_core.getData and gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return nil end
  local racer = dragData.racers[vehId]
  if racer and racer.isPlayable then return racer end
  return nil
end

local function suppressVanillaDragHudIfPractice()
  local raceSession = gameplay_events_freeroam_raceSession
  local freeroamSession = gameplay_events_freeroam_session
  if not raceSession or not raceSession.suppressVanillaDragHudApps then return end
  if freeroamSession and (freeroamSession.dragPracticeFlow or freeroamSession.dragPracticeActive) then
    raceSession.suppressVanillaDragHudApps()
  end
end

local function onDragDataSet(dragData)
  if bindLegacyTreeLights(dragData) then
    log("I", logTag, "Bound legacy christmas-tree light scene objects")
  end
  -- dragBridge.onDragDataSet re-shows topLeft dragInfo; hide again for FRE practice.
  suppressVanillaDragHudIfPractice()
end

local function onDragRacersSetup(dragData)
  bindLegacyTreeLights(dragData)

  if not isFreeroamDrag() or not dragData or not dragData.racers then return end
  local raceSession = gameplay_events_freeroam_raceSession
  if not raceSession then return end
  for _, racer in pairs(dragData.racers) do
    if racer.isPlayable then
      raceSession.beginDragPracticeFreeroamHud(racer.vehId)
      break
    end
  end
  suppressVanillaDragHudIfPractice()
end

local function onRacerPhaseTransition(vehId, oldPhase, newPhase, newPhaseName)
  if not isFreeroamDrag() then return end
  local racer = getPlayableRacer(vehId)
  if not racer then return end

  local raceSession = gameplay_events_freeroam_raceSession

  if newPhaseName == "countdown" then
    if not raceSession or not raceSession.isRaceHudShown or not raceSession.isRaceHudShown() then
      freeroamUtils.displayStagedMessage(vehId, "drag")
    end
  elseif newPhaseName == "race" then
    freeroamUtils.saveAndSetTrafficAmount(0)
    if raceSession and raceSession.isRaceHudShown and raceSession.isRaceHudShown() then
      raceSession.beginDragPracticeFreeroamRace(vehId)
    else
      freeroamUtils.displayStartMessage("drag")
    end
  elseif newPhaseName == "stop" then
    -- Pay on race-phase completion (end line), not after the stop phase.
    if racer.timers and racer.timers.time_1_4 and racer.timers.time_1_4.value and racer.timers.time_1_4.value > 0 then
      freeroamEvents.payoutDragRace("drag", racer.timers.time_1_4.value, racer.vehSpeed * 2.2369362921, vehId)
    end
  elseif newPhaseName == "finished" then
    freeroamUtils.restoreTrafficAmount()
  end
end

local function endHud()
  local raceSession = gameplay_events_freeroam_raceSession
  if raceSession and raceSession.endDragPracticeFreeroamHud then
    raceSession.endDragPracticeFreeroamHud()
  end
end

local function onDragReset()
  if isFreeroamDrag() then
    endHud()
  end
end

local function onDragClear()
  endHud()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not legacyTypeWrapped then
    wrapLegacyDragTypeRemap()
  end
  if not isFreeroamDrag() then return end
  local freeroamSession = gameplay_events_freeroam_session
  if not freeroamSession then return end

  -- Stock display.lua re-shows topCenter "drag" near the stage in freeroam.
  if freeroamSession.dragPracticeFlow or freeroamSession.dragPracticeActive then
    suppressVanillaDragHudIfPractice()
  end

  if not freeroamSession.dragPracticeActive then return end
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return end

  for _, racer in pairs(dragData.racers) do
    if racer.isPlayable and racer.phases and racer.currentPhase then
      local phase = racer.phases[racer.currentPhase]
      if phase and phase.name == "race" and racer.timersStarted then
        freeroamSession.in_race_time = (racer.timers and racer.timers.timer and racer.timers.timer.value) or 0
        local spd = (racer.vehSpeed or 0) * (freeroamSession.speedUnit or 2.2369362921)
        if spd > (freeroamSession.maxSpeed or 0) then
          freeroamSession.maxSpeed = spd
        end
      end
    end
  end
end

M.onExtensionLoaded = function()
  wrapLegacyDragTypeRemap()
end
M.onDragDataSet = onDragDataSet
M.onDragRacersSetup = onDragRacersSetup
M.onRacerPhaseTransition = onRacerPhaseTransition
M.onDragReset = onDragReset
M.onDragClear = onDragClear
M.onUpdate = onUpdate

return M
