-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local allMissionData = {}

local preMissionCycle = nil

-- Vanilla startWithFade snapshots part condition after stash has already
-- deactivated the owned career car. Vehicle Lua is dead, the ping never
-- returns, and Start sits on a 120s timeout. If the live overlay is not in
-- place yet, skip that step on the still-vanilla start path.
local function wrapMissionManagerSnapshotSkip()
  local mm = gameplay_missions_missionManager
  if not mm or mm._rlsSkipPartConditionSnapshot then return mm ~= nil end
  local origFade = mm.startWithFade
  if type(origFade) ~= 'function' then return false end
  local info = debug.getinfo(origFade, 'S')
  local src = (info and info.source) or ''
  if src:find('overrides', 1, true) or src:find('overriden', 1, true) then
    mm._rlsSkipPartConditionSnapshot = true
    return true
  end
  mm.startWithFade = function(mission, userSettings, startingOptions)
    startingOptions = startingOptions or {}
    startingOptions.skipPartConditionSnapshot = true
    return origFade(mission, userSettings, startingOptions)
  end
  mm.start = mm.startWithFade
  mm._rlsSkipPartConditionSnapshot = true
  log('I', 'missionWrapper', 'Skipping mission-start part-condition snapshot (stashed career vehicle 120s timeout)')
  return true
end

-- Belt and suspenders: if the snapshot step still runs against a dead vehicle
-- Lua VM, complete the ping immediately instead of waiting 120s.
local function wrapInactiveMissionPing()
  local vb = core_vehicleBridge
  if not vb or vb._rlsInactivePingBypass or type(vb.requestValue) ~= 'function' then
    return vb ~= nil
  end
  local origRequest = vb.requestValue
  vb.requestValue = function(veh, cb, lookup, ...)
    if lookup == 'ping' and veh and veh.getActive and not veh:getActive() then
      local mm = gameplay_missions_missionManager
      if mm and mm.isCurrentlyProcessingStep and mm.isCurrentlyProcessingStep() then
        if cb then cb() end
        return
      end
    end
    return origRequest(veh, cb, lookup, ...)
  end
  vb._rlsInactivePingBypass = true
  return true
end

local function init() end

local function setCurrentSaveSlot()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not savePath then return end
  gameplay_missions_progress.setSavePath(savePath .. "/career/missions/")
  gameplay_missions_missions.reloadCompleteMissionSystem()
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  wrapMissionManagerSnapshotSkip()
  wrapInactiveMissionPing()
  -- load from saveslot
  setCurrentSaveSlot()
end

local function onExtensionUnloaded()
  gameplay_missions_progress.setSavePath(nil)
  gameplay_missions_missions.reloadCompleteMissionSystem()
end

-- this should only be loaded when the career is active
local function onSaveCurrentProfile(currentSavePath)
  gameplay_missions_progress.setSavePath(currentSavePath .. "/career/missions/")
  for id, dirtyDate in pairs(allMissionData) do
    if gameplay_missions_progress.saveMissionSaveData(id, dirtyDate) == false then
      career_saveSystem.saveFailed()
    end
  end
end

local function setMissionInfo(id, dirtyDate)
  allMissionData[id] = dirtyDate
end

local function cacheMissionData(id, dirtyDate)
  setMissionInfo(id, dirtyDate and dirtyDate or os.date("!%Y-%m-%dT%H:%M:%SZ"))
end

local function onMissionLoaded(id, dirtyDate)
  cacheMissionData(id, dirtyDate)
end

local function saveMission(id)
  cacheMissionData(id)
  career_saveSystem.saveCurrent()
end

local function onAnyMissionChanged(state, mission)
  if mission and state == "stopped" then
    scenetree.tod.play = preMissionCycle
    preMissionCycle = nil
    career_modules_playerDriving.resetPlayerState()
    if career_career.isAutosaveEnabled() then
      saveMission(mission.id)
    end
  end
end

local missionStartStep
local function completeMissionStart()
  if not missionStartStep then return end
  missionStartStep.handlingComplete = true
  missionStartStep = nil
end

-- Inventory fires this mid-save; that's when vanilla unblocks mission start.
local function onVehicleSaveFinished()
  completeMissionStart()
end

-- Backup if the vehicle step is skipped but the save still finishes.
local function onSaveFinished()
  completeMissionStart()
end

local function preMissionHandling(step, task)
  missionStartStep = step
  if preMissionCycle == nil then
    preMissionCycle = scenetree.tod.play
  end
  scenetree.tod.play = false

  if not career_career.isAutosaveEnabled() then
    completeMissionStart()
    return
  end

  -- Deferred saveCurrent() only queues. This step waits on onVehicleSaveFinished,
  -- so cooldown/speed-gate (or a tutorial no-op) would stall the loading screen.
  career_saveSystem.saveCurrent(nil, {force = true})
  if not (career_saveSystem.isSaveBusy and career_saveSystem.isSaveBusy()) then
    completeMissionStart()
  end
end

local function onUpdate()
  wrapMissionManagerSnapshotSkip()
  wrapInactiveMissionPing()
end

M.cacheMissionData = cacheMissionData
M.onMissionLoaded = onMissionLoaded
M.saveMission = saveMission
M.preMissionHandling = preMissionHandling

M.onSaveCurrentProfile = onSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onAnyMissionChanged = onAnyMissionChanged
M.onVehicleSaveFinished = onVehicleSaveFinished
M.onSaveFinished = onSaveFinished
M.onUpdate = onUpdate

return M