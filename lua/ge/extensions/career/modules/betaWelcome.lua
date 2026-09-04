local M = {}

M.dependencies = {"career_career"}

-- Update this block for each beta cycle. Changing `id` makes the splash appear
-- once again for every tester without clearing the acknowledgement of older cycles.
local currentCycle = {
  enabled = true,
  id = "2.7.0.3",
  label = "v2.7.0.3",
  eyebrow = "CURRENT BETA CYCLE",
  title = "What's new in v2.7.0.3",
  intro = "Here are the biggest changes you will notice while playing this update.",
  changes = {
    {
      tag = "REWORKED",
      title = "Maintenance that matches your vehicle",
      body = "Service wear now follows each component's actual mileage, skips systems your vehicle does not use and correctly shows transmission work for transaxle layouts. Repair screens also give you a clearer breakdown of smaller damage."
    },
    {
      tag = "UPDATED",
      title = "Tire service without the disruption",
      body = "Repairing or replacing tires at a service location no longer respawns your vehicle. Purchased tires now keep the correct condition, and tires can be sold from My Parts."
    },
    {
      tag = "EXPANDED",
      title = "Clearer, more reliable recovery jobs",
      body = "Recovery now includes a job summary, a clearer phone icon and more dependable vehicle selection. Wheel-less and heavily damaged recoveries are handled better, while roleplay vehicles are kept out of the job pool."
    },
    {
      tag = "EXPANDED",
      title = "More control over Marketplace listings",
      body = "You can edit an active vehicle listing, sell damaged vehicles and still accept an offer if a listed vehicle was damaged afterward. Marketplace pages also return to the top when you browse."
    },
    {
      tag = "UPDATED",
      title = "Safer parts, tuning and paint saves",
      body = "Parts and tuning changes now save in order so a purchased tune is less likely to be lost. Backing out of My Parts, tuning or paint also closes the session cleanly after a save."
    },
    {
      tag = "UPDATED",
      title = "Car meet progress now sticks",
      body = "Club membership and scene reputation now persist correctly. Car meet purchases use the proper sale flow, and several issues that could reset progress or interrupt a meet have been fixed."
    },
    {
      tag = "UPDATED",
      title = "Better garage and autosave behavior",
      body = "Five-minute autosaves are restored, garage computers behave more consistently and starter garages once again require payment. Chinatown Overflow now has a standard computer and is priced at $65,000."
    },
    {
      tag = "UPDATED",
      title = "Fewer unwanted police pursuits",
      body = "Walking, retrieving a vehicle, driving a loaner or working as police is less likely to trigger an incorrect pursuit. The standard BeamNG taxi service is restored and remains exempt from police targeting while on duty."
    },
    {
      tag = "UPDATED",
      title = "Cleaner missions, traffic and parking",
      body = "Traffic returns more cleanly after vanilla missions, parked vehicles spread out more naturally and routes avoid several invisible roads around the recovery yard and quarry. Loaners also spawn in their parking spaces more reliably."
    },
    {
      tag = "UPDATED",
      title = "Racing, weather and vehicle fixes",
      body = "AI racers received an aggression pass, modded configurations are filtered more reliably for eligible races and fog now follows the intended weather conditions. The Career MD-Series also has improved air-system performance."
    }
  }
}

local pendingShow = false

local function getSummary(force)
  local summary = deepcopy(currentCycle)
  summary.force = force == true
  return summary
end

local function isCareerUiReady()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return false
  end
  if core_gamestate and core_gamestate.getLoadingStatus then
    if core_gamestate.getLoadingStatus("careerLoading") then return false end
    if core_gamestate.getLoadingStatus("careerActivate") then return false end
  end
  return true
end

local function requestSplash(force)
  if not currentCycle.enabled then return nil end
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return nil
  end

  local ready = force == true or isCareerUiReady()
  pendingShow = not ready
  local summary = getSummary(force)
  summary.interactive = ready
  if guihooks and guihooks.trigger then
    guihooks.trigger("RlsBetaCycleSplashShow", summary)
  end
  return summary
end

local function onCareerActivated()
  requestSplash(false)
end

local function onWorldReadyState(state)
  if state ~= 2 then return end
  if pendingShow then
    requestSplash(false)
  end
end

M.getSummary = getSummary
M.isCareerUiReady = isCareerUiReady
M.requestSplash = requestSplash
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = onWorldReadyState

return M
