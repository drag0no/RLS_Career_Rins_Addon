local M = {}

local freConfig = require('gameplay/fre/config')
local freHelpers = require('gameplay/events/freContracts/helpers')

local function acceptContract(contractId)
  local blockMsg = freHelpers.getFreeroamEventContractBlockMessage()
  if blockMsg then
    return false, blockMsg
  end
  local state = gameplay_events_freContracts_state.getState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.contracts.available) do
      if entry.id == contractId then
        if (tonumber(entry.expiresAt) or 0) <= now then
          table.remove(dState.contracts.available, idx)
          gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
          gameplay_events_freContracts_ui.emitUiStateUpdate("contract_offer_expired")
          return false, "Offer expired."
        end
        local requiredModel = entry.requiredModel
        if requiredModel and requiredModel ~= "" and
          (not gameplay_events_freContracts_vehiclePool.isModelAllowedForDiscipline(discipline.id, requiredModel) or not gameplay_events_freContracts_vehiclePool.isValidVehicleModelKey(requiredModel)) then
          table.remove(dState.contracts.available, idx)
          gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
          gameplay_events_freContracts_ui.emitUiStateUpdate("contract_offer_expired")
          return false, "Required model is invalid or blacklisted."
        end
        local tiers = gameplay_events_freContracts_skills.getUnlockedContractTiers(discipline.id,
          gameplay_events_freContracts_skills.getSkillLevel(discipline.id))
        local licensed = false
        for _, tierName in ipairs(tiers) do if tierName == (entry.tier or "easy") then licensed = true end end
        if not licensed then return false, "That contract license is not unlocked." end
        local slotCap = gameplay_events_freContracts_skills.getSharedSlotCap(discipline.id, "contracts")
        local used = gameplay_events_freContracts_skills.countActiveForParent(discipline.parentSkillId, "contracts")
        if used >= slotCap then
          return false, "No contract slots available."
        end
        local tier = entry.tier or "easy"
        local ttl = tonumber(((freConfig.getContractConfig(discipline.id) or {}).expiryMinutesByTier or {})[tier]) or 60
        entry.expiresAt = now + ttl
        entry.acceptedAt = now
        table.insert(dState.contracts.active, entry)
        table.remove(dState.contracts.available, idx)
        gameplay_events_freContracts_state.saveNow()
        gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
        gameplay_events_freContracts_ui.emitUiStateUpdate("contract_accepted")
        return true
      end
    end
  end
  return false, "Contract not found."
end

local function abandonContract(contractId)
  local state = gameplay_events_freContracts_state.getState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.contracts.active) do
      if entry.id == contractId then
        dState.contracts.failed = dState.contracts.failed + 1
        table.remove(dState.contracts.active, idx)
        gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
        gameplay_events_freContracts_ui.emitUiStateUpdate("contract_abandoned")
        return true
      end
    end
  end
  return false, "Contract not found."
end

local function signSponsor(sponsorId)
  local state = gameplay_events_freContracts_state.getState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.sponsors.available) do
      if entry.id == sponsorId then
        if (tonumber(entry.expiresAt) or 0) <= now then
          table.remove(dState.sponsors.available, idx)
          gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
          gameplay_events_freContracts_ui.emitUiStateUpdate("sponsor_offer_expired")
          return false, "Offer expired."
        end
        local tiers = gameplay_events_freContracts_skills.getUnlockedSponsorTiers(discipline.id,
          gameplay_events_freContracts_skills.getSkillLevel(discipline.id))
        local eligible = false
        for _, tierName in ipairs(tiers) do if tierName == (entry.tier or "easy") then eligible = true end end
        if not eligible then return false, "That sponsor tier is not unlocked." end
        if not gameplay_events_freContracts_skills.hasFreeSponsorSlot(discipline.id) then
          return false, "No sponsor slots available."
        end
        entry.warningIssued = false
        entry.warningIssuedAt = nil
        entry.probation = true
        local sponsorCfg = freConfig.getSponsorConfig(discipline.id) or {}
        local probationMinutes = tonumber((sponsorCfg.probationMinutesByTier or {})[entry.tier]) or 30
        entry.nextCheckAt = now + probationMinutes
        table.insert(dState.sponsors.active, entry)
        table.remove(dState.sponsors.available, idx)
        gameplay_events_freContracts_state.saveNow()
        gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
        gameplay_events_freContracts_ui.emitUiStateUpdate("sponsor_signed")
        return true
      end
    end
  end
  return false, "Sponsor not found."
end

local function dropSponsor(sponsorId)
  local state = gameplay_events_freContracts_state.getState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for idx, entry in ipairs(dState.sponsors.active) do
      if entry.id == sponsorId then
        dState.sponsors.dropped = dState.sponsors.dropped + 1
        table.remove(dState.sponsors.active, idx)
        local parentState = gameplay_events_freContracts_skills.getParentSkillState(discipline.parentSkillId)
        parentState.sponsorSlotCooldowns = parentState.sponsorSlotCooldowns or {}
        local cooldown = tonumber((freConfig.getSponsorConfig(discipline.id) or {}).droppedSlotCooldownMinutes) or 15
        table.insert(parentState.sponsorSlotCooldowns, now + cooldown)
        gameplay_events_freContracts_state.saveNow()
        gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
        gameplay_events_freContracts_ui.emitUiStateUpdate("sponsor_dropped")
        return true
      end
    end
  end
  return false, "Sponsor not found."
end

local function upgradeLicense(disciplineId)
  local ok, err, tier = gameplay_events_freContracts_skills.upgradeLicense(disciplineId)
  if not ok then return false, err end
  local now = gameplay_events_freContracts_state.getSimTime()
  local offerGenerated, offerMessage = false, nil
  if gameplay_events_freContracts_offers.generateImmediateContractOffer then
    offerGenerated, offerMessage = gameplay_events_freContracts_offers.generateImmediateContractOffer(disciplineId, now)
  end
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
  gameplay_events_freContracts_ui.emitUiStateUpdate("license_upgraded")
  return true, nil, tier, offerGenerated, offerMessage
end

local function acknowledgeSponsorWarning(sponsorId)
  local state = gameplay_events_freContracts_state.getState()
  local now = tonumber(state.simTime) or 0
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    for _, entry in ipairs(dState.sponsors.active) do
      if entry.id == sponsorId then
        entry.warningAcknowledgedAt = now
        gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
        gameplay_events_freContracts_ui.emitUiStateUpdate("sponsor_warning_acknowledged")
        return true
      end
    end
  end
  return false, "Sponsor not found."
end

M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.signSponsor = signSponsor
M.dropSponsor = dropSponsor
M.acknowledgeSponsorWarning = acknowledgeSponsorWarning
M.upgradeLicense = upgradeLicense

return M
