local M = {}

function M.isEnabled()
  local em = rawget(_G, "overhaul_extensionManager")
  if not (em and em.isDevKeyValid and em.isDevKeyValid()) then
    return false
  end
  local settings = rawget(_G, "overhaul_settings")
  if not (settings and settings.getSetting) then
    return false
  end
  return settings.getSetting("racingTeamDevConsole") == true
end

function M.requireEnabled()
  if not M.isEnabled() then
    return false, "dev_console_disabled"
  end
  return true
end

return M
