local M = {}

local REFRESH_THRESHOLD_SECONDS = 3600

local devConsole = require("ge/extensions/career/modules/devConsole")
local rtState = require("ge/extensions/career/modules/business/racingTeamRuntimeState")

local MAX_LINES = 200
local buffer = {}
local seq = 0

local function enabled()
  return devConsole.isEnabled()
end

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function formatContext(ctx)
  if type(ctx) ~= "table" then
    return ""
  end
  local parts = {}
  for k, v in pairs(ctx) do
    local t = type(v)
    if t ~= "table" and t ~= "function" then
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  if #parts == 0 then
    return ""
  end
  return " (" .. table.concat(parts, ", ") .. ")"
end

local function formatEntry(entry)
  local lvl = string.upper(tostring(entry.level or "info"))
  local src = entry.source and ("[" .. tostring(entry.source) .. "] ") or ""
  return src .. "[" .. lvl .. "] " .. tostring(entry.message or "") .. formatContext(entry.context)
end

local function pushUi(payload)
  if guihooks and guihooks.trigger then
    guihooks.trigger("racingTeam:devLog", payload)
  end
end

function M.append(businessId, level, message, source, context)
  if not enabled() then
    return
  end
  if not message or message == "" then
    return
  end
  seq = seq + 1
  local entry = {
    seq = seq,
    level = level or "info",
    message = tostring(message),
    source = source,
    context = type(context) == "table" and context or nil,
    businessId = businessId and tostring(normalizeBusinessId(businessId)) or nil,
  }
  buffer[#buffer + 1] = entry
  while #buffer > MAX_LINES do
    table.remove(buffer, 1)
  end
  local text = formatEntry(entry)
  log("I", "racingTeamDev", text)
  pushUi({ text = text, level = entry.level })
end

function M.getFormattedLines()
  local out = {}
  for i = 1, #buffer do
    out[i] = formatEntry(buffer[i])
  end
  return out
end

function M.clear()
  buffer = {}
  seq = 0
  if enabled() then
    pushUi({ clear = true })
  end
end

function M.scanIssues(businessId)
  if not enabled() or not businessId then
    return
  end
  businessId = normalizeBusinessId(businessId)
  local id = tostring(businessId)
  local rt = rtState.rtInternal
  if not rt or not rt.getCurrentLeague then
    return
  end

  local league = rt.getCurrentLeague(businessId)
  local board = rt.getRaceOfferBoard and rt.getRaceOfferBoard(businessId)
  local offerCount = board and #(board.offers or {}) or 0
  if offerCount == 0 then
    M.append(businessId, "warn", "Race offer board is empty", "scan")
  end
  if board and board.nextRefreshAt then
    local now = rt.getCareerSimTime and rt.getCareerSimTime() or 0
    local refreshAt = tonumber(board.nextRefreshAt) or 0
    if refreshAt > now + REFRESH_THRESHOLD_SECONDS then
      M.append(businessId, "warn", "Race board refresh far in future (" .. tostring(math.floor(refreshAt - now)) .. "s sim)", "scan")
    end
  end

  local invMod = require("ge/extensions/career/modules/business/racingTeamLeagueInvite")
  local inv = invMod.getInviteTable(businessId)
  if inv and inv.declined then
    M.append(businessId, "warn", "League invite was declined (target " .. tostring(inv.targetLeague) .. ")", "scan")
  end
  if inv and inv.offeredAt and not inv.declined and inv.targetLeague then
    M.append(businessId, "info", "Pending league invite to " .. tostring(inv.targetLeague), "scan")
  end

  if rtState.pendingRematchOfferByBusiness[id] then
    M.append(businessId, "info", "Pending rematch offer stored", "scan")
  end

  local goalsMod = require("ge/extensions/career/modules/business/racingTeamGoals")
  local def = goalsMod.loadDefinition()
  local leagueGoals = goalsMod.getSortedForLeague(def, league)
  local headGoal = nil
  for _, g in ipairs(leagueGoals or {}) do
    if g and g.id and not goalsMod.idCompleted(businessId, g.id) then
      headGoal = g.id
      break
    end
  end
  if not headGoal and leagueGoals and #leagueGoals > 0 then
    if rt.allGoalsCompleteForLeague and rt.allGoalsCompleteForLeague(businessId, league) then
      M.append(businessId, "info", "All goals complete for " .. tostring(league), "scan")
    else
      M.append(businessId, "warn", "No head goal but league not fully complete", "scan")
    end
  end
end

rtState.rtInternal.devLog = M

return M
