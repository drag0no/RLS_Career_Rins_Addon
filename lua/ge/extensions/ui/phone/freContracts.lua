local freConfig = require('gameplay/fre/config')

local M = {}

M.dependencies = {'gameplay_events_freContracts'}

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local function getState(filterDisciplineId)
  if not isCareerActive() then
    return {
      careerActive = false,
      disciplines = {},
      activeContracts = {},
      availableContracts = {},
      activeSponsors = {},
      availableSponsors = {},
      sanctionedRacing = nil,
      sanctionedRacingOfferPeriodMinutes = nil,
    }
  end

  local state = gameplay_events_freContracts_ui.getUiState(filterDisciplineId)
  state = type(state) == "table" and state or {}
  state.careerActive = true
  return state
end

local function actionResult(ok, err)
  return {
    ok = ok == true,
    error = ok and nil or (err or "Action failed.")
  }
end

local function startLiveUpdates()
  gameplay_events_freContracts_ui.setUiStreamingActive(true)
  return true
end

local function stopLiveUpdates()
  gameplay_events_freContracts_ui.setUiStreamingActive(false)
  return true
end

local function acceptContract(contractId)
  local ok, err = gameplay_events_freContracts_actions.acceptContract(contractId)
  return actionResult(ok, err)
end

local function abandonContract(contractId)
  local ok, err = gameplay_events_freContracts_actions.abandonContract(contractId)
  return actionResult(ok, err)
end

local function signSponsor(sponsorId)
  local ok, err = gameplay_events_freContracts_actions.signSponsor(sponsorId)
  return actionResult(ok, err)
end

local function dropSponsor(sponsorId)
  local ok, err = gameplay_events_freContracts_actions.dropSponsor(sponsorId)
  return actionResult(ok, err)
end

local function acknowledgeSponsorWarning(sponsorId)
  local ok, err = gameplay_events_freContracts_actions.acknowledgeSponsorWarning(sponsorId)
  return actionResult(ok, err)
end

local function upgradeLicense(disciplineId)
  local ok, err, tier, offerGenerated, offerMessage = gameplay_events_freContracts_actions.upgradeLicense(disciplineId)
  local result = actionResult(ok, err)
  result.tier = tier
  result.offerGenerated = offerGenerated == true
  result.message = offerMessage
  return result
end

local function commitSanctionedRace()
  local ok, err = gameplay_events_freContracts_sanctionedRacing.commitSanctionedRace()
  return actionResult(ok, err)
end

local function navigateSanctionedRace()
  local ok, err = gameplay_events_freContracts_sanctionedRacing.navigateSanctionedRace()
  return actionResult(ok, err)
end

local function rescheduleSanctionedRace()
  local ok, err = gameplay_events_freContracts_sanctionedRacing.rescheduleSanctionedRace()
  return actionResult(ok, err)
end

local function getVehicleNiceName(vehicle, vPool)
    local name = vehicle.niceName
    if not name or name == "" then
      local displayName = vPool and vPool.getModelDisplayName and vPool.getModelDisplayName(vehicle.model)
      local modelName = displayName or vehicle.model or "Vehicle"
      if vehicle.configName and vehicle.configName ~= "" then
        name = modelName .. " " .. vehicle.configName
      else
        name = modelName
      end
    end
    return name
end

local function getNotificationFilterOptions()
  local vPool = gameplay_events_freContracts_vehiclePool
  if not vPool and extensions and extensions.load then
    pcall(extensions.load, "gameplay_events_freContracts_vehiclePool")
    vPool = gameplay_events_freContracts_vehiclePool
  end

  local vehicles = {}
  if isCareerActive() and career_modules_inventory and career_modules_inventory.getVehicles then
    vehicles = career_modules_inventory.getVehicles() or {}
  end

  local ownedCars = {}
  for invId, veh in pairs(vehicles) do
    table.insert(ownedCars, {
      id = tostring(invId),
      name = getVehicleNiceName(veh, vPool),
      model = veh.model or "",
    })
  end
  table.sort(ownedCars, function(a, b)
    return string.lower(a.name) < string.lower(b.name)
  end)

  local disciplinesList = {}
  if freConfig and freConfig.getDisciplines then
    for _, disc in ipairs(freConfig.getDisciplines() or {}) do
      if not disc.legacyOnly and not disc.placeholderOnly then
        table.insert(disciplinesList, {
          id = disc.id,
          label = disc.label or disc.id,
        })
      end
    end
  end

  local difficulties = {
    { id = "easy", label = "Easy" },
    { id = "medium", label = "Medium" },
    { id = "hard", label = "Hard" },
  }

  return {
    ownedCars = ownedCars,
    disciplines = disciplinesList,
    difficulties = difficulties,
  }
end

M.getState = getState
M.startLiveUpdates = startLiveUpdates
M.stopLiveUpdates = stopLiveUpdates
M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.signSponsor = signSponsor
M.dropSponsor = dropSponsor
M.acknowledgeSponsorWarning = acknowledgeSponsorWarning
M.upgradeLicense = upgradeLicense
M.commitSanctionedRace = commitSanctionedRace
M.navigateSanctionedRace = navigateSanctionedRace
M.rescheduleSanctionedRace = rescheduleSanctionedRace
M.getNotificationFilterOptions = getNotificationFilterOptions

return M
