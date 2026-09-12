-- Competitive circuit track flow: grid countdown, staging parking, sanctioned dispatch.
local M = {}

M.dependencies = { 'gameplay_events_freeroam_session', 'core_jobsystem', 'core_gamestate' }

M.TRACK_RACE_ID = "track"

M.trackFlowState = {
    useAltRoute = false,
    inTrackFlowContext = false,
    sanctionedCareerGoToRaceActive = false,
    sanctionedPoolRefPw = nil,
    sanctionedRaceLapCount = nil,
    -- Racing team proxy: staging at track (not phone sanctioned).
    racingTeamProxyRaceActive = false,
    racingTeamProxyBusinessId = nil,
    racingTeamProxyFleetVehicleId = nil,
    racingTeamProxyRaceSession = false,
    racingTeamProxySessionBusinessId = nil,
    racingTeamProxySessionFleetVehicleId = nil,
    --- Racing-team proxy: sanctioned classPwMax/classPwMin (hp/kg) from offer snapshot; legacy keys *AiPoolRefHp.
    racingTeamProxyAiPoolRefHp = nil,
    racingTeamProxyAiPoolMinHp = nil,
    --- When true, AI spawn picks random configs in [classPwMin, classPwMax] only (ignores live player hp/kg).
    racingTeamProxyAiPoolBracketOnly = false,
    --- 0..1 from proxy driver skill tier; passed to AI spawn only (offer/UI unchanged).
    racingTeamProxyAiDifficultyT = nil,
    --- When not false, show mod Vue fullscreen (`racingTeamProxyTeamLoading`) during racing-team proxy staging; not phone/sanctioned.
    racingTeamProxyStagingLoadingOverlay = true,
}

local TRACK_GRID_STAGE_STOP_MPH = 2.5
local TRACK_GRID_PARKING_COMMIT_PADDING_M = 0.25
local TRACK_GRID_AI_SPAWN_WAIT_SEC = 12
--- After showing proxy team loading overlay, yield this long so it can paint before teleport/enter.
local RACING_TEAM_PROXY_TEAM_LOADING_PAINT_DELAY_SEC = 0.45
--- Total AI-spawn attempts under the proxy loading overlay before bailing (1 initial + retries).
local MAX_PROXY_STAGING_AI_ATTEMPTS = 2

local mCompetitiveAwaitingAiSpawn = false
local mTrackGridParkingAiSpawnStarted = false
local mTrackGridAiSpawnWaitDeadline = nil
local mCompetitiveCountdownJobActive = false
local mCompetitiveCountdownCancel = false
local mPlayerStagingSpot = nil

local SANCTIONED_PARKING_UI_PUSH_INTERVAL = 0.2
local SANCTIONED_PARKING_LIVE_HP_REFRESH_INTERVAL = 2
local mSanctionedParkingUiPhase = "hidden"
local mSanctionedParkingUiPushClock = nil
local mSanctionedParkingLiveRefreshClock = nil

local SANCTIONED_CLASS_BRANCHES = { "stock", "modified", "super", "open" }

local function sanitizeBracketLabel(label)
    local s = tostring(label or ""):lower()
    s = s:gsub("%s*%b()%s*$", "")
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeClassTier(label)
    local s = tostring(label or ""):lower()
    if s:find("entry", 1, true) or s:find("low", 1, true) or s:find("lower", 1, true) then
        return "entry"
    end
    if s:find("upper", 1, true) or s:find("high", 1, true) then
        return "upper"
    end
    if s:find("mid", 1, true) or s:find("medium", 1, true) then
        return "mid"
    end
    return ""
end

local function resolveClassBranch(label, branch)
    local src = tostring(label or ""):lower()
    for _, b in ipairs(SANCTIONED_CLASS_BRANCHES) do
        if src:find(b, 1, true) then
            return b
        end
    end
    local fromBranch = tostring(branch or ""):lower()
    for _, b in ipairs(SANCTIONED_CLASS_BRANCHES) do
        if fromBranch:find(b, 1, true) then
            return b
        end
    end
    return ""
end

local function pwBucketX1000(pw)
    local n = tonumber(pw)
    if not n or n <= 0 then
        return nil
    end
    return math.floor((n * 1000) / 50) * 50
end

local function formatSanctionedClassWithBucket(label, branch, pwSource)
    local clean = sanitizeBracketLabel(label)
    local b = resolveClassBranch(clean, branch)
    local tier = normalizeClassTier(clean)
    local compact = ""
    if b ~= "" and tier ~= "" then
        compact = b .. "-" .. tier
    elseif b ~= "" then
        compact = b
    end
    if compact == "open" then
        return "open (500+)", 500
    end
    local bucket = pwBucketX1000(pwSource)
    if compact ~= "" and bucket then
        return string.format("%s (%d)", compact, bucket), bucket
    end
    if compact ~= "" then
        return compact, bucket
    end
    if bucket then
        return string.format("pw (%d)", bucket), bucket
    end
    return "", nil
end

local DEFAULT_PLAYER_STAGING_SPOT_NAME = "player_stage_track"
local mCachedPlayerStagingSpotName = nil
local mCachedPlayerStagingSpotNameLevel = nil
local mPlayerStagingCornerMarkers = {}
local mRacingTeamProxyNextAttemptClock = nil
--- True while async proxy staging job runs (teleport+AI tail or begin-tail; prevents parking loop from double-scheduling).
local mRacingTeamProxyStagingTeleportJobActive = false

--- True while UI is reduced to RacingTeamProxyOverlay + freeroamRaceHud (body overlays); dock/canvas apps hidden.
--- Includes `spectateStaging` (Spectate clicked) before teleport / in-race.
local mRacingTeamProxySpectatorUiMinimalActive = false

local function getGameplayAppContainersExt()
    if not extensions then
        return nil
    end
    local names = { "ui_gameplayAppContainers", "ge_extensions_ui_gameplayAppContainers" }
    for _, n in ipairs(names) do
        local gc = extensions[n]
        if gc and gc.hideAllApps then
            return gc
        end
    end
    return nil
end

local function getMessagesTasksAppContainersExt()
    if not extensions then
        return nil
    end
    local names = { "ui_messagesTasksAppContainers", "ge_extensions_ui_messagesTasksAppContainers" }
    for _, n in ipairs(names) do
        local mc = extensions[n]
        if mc and mc.hideAllApps then
            return mc
        end
    end
    return nil
end

local function runRacingTeamProxySpectatorUiMinimalEffects()
    local gc = getGameplayAppContainersExt()
    if gc then
        pcall(function()
            gc.hideAllApps("gameplayApps")
        end)
    end
    local mc = getMessagesTasksAppContainersExt()
    if mc then
        pcall(function()
            mc.hideAllApps("messagesTasksApps")
        end)
    end
    if guihooks and guihooks.trigger then
        guihooks.trigger("ShowApps", false)
        guihooks.trigger("appContainer:clear")
    end
end

local function applyRacingTeamProxySpectatorUiMinimal()
    if mRacingTeamProxySpectatorUiMinimalActive then
        return
    end
    mRacingTeamProxySpectatorUiMinimalActive = true
    runRacingTeamProxySpectatorUiMinimalEffects()
end

--- Re-apply hide/clear while proxy minimal mode is active (e.g. CEF restored chrome after alt-tab).
function M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    if not mRacingTeamProxySpectatorUiMinimalActive then
        return
    end
    runRacingTeamProxySpectatorUiMinimalEffects()
end

--- Same as `refreshRacingTeamProxySpectatorUiMinimalIfActive`; local alias for call sites in this file.
local function refreshProxySpectatorUiIfMinimal()
    M.refreshRacingTeamProxySpectatorUiMinimalIfActive()
end

local function restoreRacingTeamProxySpectatorUiAfterMinimal()
    if not mRacingTeamProxySpectatorUiMinimalActive then
        return
    end
    mRacingTeamProxySpectatorUiMinimalActive = false
    if not guihooks or not guihooks.trigger then
        return
    end
    guihooks.trigger("ShowApps", true)
    local al = nil
    if core_gamestate and core_gamestate.state and core_gamestate.state.appLayout ~= nil then
        al = core_gamestate.state.appLayout
    end
    if type(al) == "string" and al ~= "" then
        if al == "blank" then
            guihooks.trigger("appContainer:clear")
        else
            guihooks.trigger("appContainer:loadLayoutByType", al)
        end
    elseif type(al) == "table" then
        guihooks.trigger("appContainer:loadLayoutByObject", al)
    else
        guihooks.trigger("appContainer:loadLayoutByType", "freeroam")
    end
end

local function racingTeamProxyUseTeamLoadingOverlay()
    return M.trackFlowState.racingTeamProxyStagingLoadingOverlay ~= false
end

--- Mod-owned fullscreen (Vue); not `core_gamestate` careerLoading.
local function relayRacingTeamProxyTeamLoading(visible, message)
    if not guihooks or not guihooks.trigger then
        return
    end
    if visible == true and not racingTeamProxyUseTeamLoadingOverlay() then
        return
    end
    local payload = { visible = visible == true }
    if visible == true and type(message) == "string" and message ~= "" then
        payload.message = message
    end
    guihooks.trigger("racingTeamProxyTeamLoading", payload)
end

--- Trigger `racingTeamProxyOverlay` and keep HUD layers consistent: only RacingTeamProxyOverlay + freeroamRaceHud while in-world proxy.
--- `spectateStaging` is set when the player starts the spectate flow (simulate); enables UI suppression before teleport / in-race.
function M.relayRacingTeamProxyOverlay(payload)
    if not guihooks or not guihooks.trigger then
        return
    end
    if type(payload) ~= "table" then
        guihooks.trigger("racingTeamProxyOverlay", payload)
        return
    end
    guihooks.trigger("racingTeamProxyOverlay", payload)
    if payload.visible == false then
        relayRacingTeamProxyTeamLoading(false)
        restoreRacingTeamProxySpectatorUiAfterMinimal()
    elseif payload.visible == true and (payload.inRace == true or payload.playerTeleportedToTeamCar == true or payload.spectateStaging == true) then
        applyRacingTeamProxySpectatorUiMinimal()
    end
end

--- Show proxy team loading immediately (e.g. after preflight); safe to call repeatedly.
function M.enterRacingTeamProxyStagingLoadingEarly()
    relayRacingTeamProxyTeamLoading(true)
end

--- Call from UI on Spectate before rAF / simulate: spectator minimal UI + team loading so nothing flashes under the computer.
function M.preflightRacingTeamProxySpectateUi(businessId)
    if businessId == nil or businessId == "" then
        return
    end
    M.relayRacingTeamProxyOverlay({
        visible = true,
        businessId = tostring(businessId),
        inRace = false,
        spectateStaging = true,
    })
    relayRacingTeamProxyTeamLoading(true)
end

--- Hide proxy team loading (arm failure, begin failure, staged, or abort).
function M.exitRacingTeamProxyStagingLoadingScreen()
    relayRacingTeamProxyTeamLoading(false)
end

--- Returns player hp/kg for AI pool reference (never catalog crank HP).
local function racingTeamProxyGetRefPwForProxyAiSpawn()
    local refPw = nil
    if type(M.trackFlowState.racingTeamProxyAiPoolRefHp) == "number" and M.trackFlowState.racingTeamProxyAiPoolRefHp > 0 then
        refPw = M.trackFlowState.racingTeamProxyAiPoolRefHp
    elseif career_modules_competitiveRace_aiRacers then
        local ar = career_modules_competitiveRace_aiRacers
        if ar.getPlayerVehiclePwForStagingUi then
            refPw = select(1, ar.getPlayerVehiclePwForStagingUi())
        elseif ar.getPlayerVehiclePowerAndClass then
            refPw = select(1, ar.getPlayerVehiclePowerAndClass())
        end
    end
    return refPw
end

--- Assigned after syncRacingTeamProxyBracketFromRequest/racingTeamRaceFlowMod are defined (forward upvalue).
local racingTeamProxyResyncAiBracketFromArmedRequest

--- Clear AI-spawn bookkeeping so a retry can re-run prepareFreeroamAiForTrack (which early-outs while awaiting).
local function racingTeamProxyResetAiSpawnBookkeeping()
    mCompetitiveAwaitingAiSpawn = false
    mTrackGridAiSpawnWaitDeadline = nil
    mTrackGridParkingAiSpawnStarted = false
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.clearSpawned then
        pcall(function() aiRacers.clearSpawned() end)
    end
end

--- One AI spawn pass + bounded wait for the async spawn callback (proxy only; called from jobsystem).
local function racingTeamProxySpawnAiAndWait(job)
    local refPw = racingTeamProxyGetRefPwForProxyAiSpawn()
    M.prepareFreeroamAiForTrack(refPw, true)
    local deadline = (os and os.time) and (os.time() + TRACK_GRID_AI_SPAWN_WAIT_SEC + 2) or 0
    while mCompetitiveAwaitingAiSpawn do
        if os and os.time and os.time() >= deadline then
            if log then
                log("W", "competitiveTrackFlow", "racing team proxy staging: AI spawn wait deadline reached.")
            end
            break
        end
        job.sleep(0.08)
    end
    job.sleep(0.12)
end

--- After player is in team car at staging: spawn AI, retry once if none appear, then bail (proxy only; jobsystem).
local function racingTeamProxyRunStagingTailAfterPlayerInTeamCar(job)
    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
        local attempt = 1
        racingTeamProxySpawnAiAndWait(job)
        while M.spawnedTrackAiCount() == 0 and attempt < MAX_PROXY_STAGING_AI_ATTEMPTS do
            if not M.trackFlowState.racingTeamProxyRaceActive then
                return
            end
            attempt = attempt + 1
            if log then
                log("W", "competitiveTrackFlow", string.format("racing team proxy staging: 0 AI on grid; retry attempt %d.", attempt))
            end
            relayRacingTeamProxyTeamLoading(true, "Loading opponents…")
            racingTeamProxyResetAiSpawnBookkeeping()
            if racingTeamProxyResyncAiBracketFromArmedRequest then
                racingTeamProxyResyncAiBracketFromArmedRequest()
            end
            racingTeamProxySpawnAiAndWait(job)
        end
        if M.spawnedTrackAiCount() == 0 then
            if log then
                log("E", "competitiveTrackFlow", "racing team proxy staging: failed to spawn AI after retries; aborting load-in.")
            end
            M.abortRacingTeamProxyStagingLoadIn("ai_spawn_failed")
            return
        end
    else
        job.sleep(0.05)
    end
    refreshProxySpectatorUiIfMinimal()
end

local function racingTeamRaceFlowMod()
    return rawget(_G, "career_modules_business_racingTeamRaceFlow")
end

local function syncRacingTeamProxyBracketFromRequest(req)
    M.trackFlowState.racingTeamProxyAiPoolRefHp = nil
    M.trackFlowState.racingTeamProxyAiPoolMinHp = nil
    M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
    M.trackFlowState.racingTeamProxyAiDifficultyT = nil
    if not req or type(req.offerSnapshot) ~= "table" then
        return
    end
    local hmax = tonumber(req.offerSnapshot.classPwMax) or tonumber(req.offerSnapshot.classHpMax)
    local hmin = tonumber(req.offerSnapshot.classPwMin) or tonumber(req.offerSnapshot.classHpMin)
    if hmax and hmax > 0 then
        M.trackFlowState.racingTeamProxyAiPoolRefHp = hmax
    end
    if hmin and hmin > 0 then
        M.trackFlowState.racingTeamProxyAiPoolMinHp = hmin
    end
    if hmax and hmax > 0 and hmin and hmin > 0 and hmax >= hmin then
        M.trackFlowState.racingTeamProxyAiPoolBracketOnly = true
        local bid = req.businessId
        local did = tonumber(req.driverId)
        local rf = racingTeamRaceFlowMod()
        if rf and rf.getProxyDriverAiDifficultyBlendT and bid and did then
            M.trackFlowState.racingTeamProxyAiDifficultyT = rf.getProxyDriverAiDifficultyBlendT(bid, did)
        else
            M.trackFlowState.racingTeamProxyAiDifficultyT = 1
        end
    end
end

--- prepareFreeroamAiForTrack consumes the bracket/difficulty fields; re-pull them from the armed request for a retry.
racingTeamProxyResyncAiBracketFromArmedRequest = function()
    local bid = M.trackFlowState.racingTeamProxyBusinessId
    local rf = racingTeamRaceFlowMod()
    if not bid or not rf or not rf.getProxyDriverRaceRequest then
        return
    end
    local req = rf.getProxyDriverRaceRequest(bid)
    if req then
        syncRacingTeamProxyBracketFromRequest(req)
    end
end

local function getPlayerStagingSpotNameForLevel()
    local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
    if not levelId or levelId == "" then
        return DEFAULT_PLAYER_STAGING_SPOT_NAME
    end
    if mCachedPlayerStagingSpotNameLevel == levelId and mCachedPlayerStagingSpotName then
        return mCachedPlayerStagingSpotName
    end
    local path = "levels/" .. levelId .. "/competitiveRace/aiRacingConfig.json"
    local data = jsonReadFile(path)
    local name = DEFAULT_PLAYER_STAGING_SPOT_NAME
    if type(data) == "table" and type(data.playerStagingSpotName) == "string" and data.playerStagingSpotName ~= "" then
        name = data.playerStagingSpotName
    end
    mCachedPlayerStagingSpotName = name
    mCachedPlayerStagingSpotNameLevel = levelId
    return name
end

function M.getPlayerStagingSpotName()
    return getPlayerStagingSpotNameForLevel()
end

--- Override spot name (e.g. tests). Pass nil to use aiRacingConfig.json / default again.
function M.setPlayerStagingSpotNameOverride(name)
    if name == nil or name == "" then
        mCachedPlayerStagingSpotName = nil
        mCachedPlayerStagingSpotNameLevel = nil
        return
    end
    mCachedPlayerStagingSpotName = name
    mCachedPlayerStagingSpotNameLevel = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or ""
end

local function sess()
    return gameplay_events_freeroam_session
end

local core_groundMarkers = nil
do
    local ok, gm = pcall(function() return require('core/groundMarkers') end)
    if ok and gm then core_groundMarkers = gm end
end

local function getStagingSpotHalfExtents(spot)
    if not spot or not spot.scl then return nil end
    local s = spot.scl
    return { (s[1] or 3) * 0.5, (s[2] or 6) * 0.5, (s[3] or 2) * 0.5 }
end

local function isPointInStagingSpot(spot, wx, wy, wz)
    if not spot or not spot.pos or not spot.scl then return false end
    local he = getStagingSpotHalfExtents(spot)
    if not he then return false end
    local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
    local sx, sy, sz = he[1], he[2], he[3]
    local dx, dy, dz = wx - px, wy - py, wz - pz
    if spot.rot and spot.rot[4] then
        local ok, localPt = pcall(function()
            local r = spot.rot
            local invQ = quat(-(r[1] or 0), -(r[2] or 0), -(r[3] or 0), r[4] or 1)
            return invQ * vec3(dx, dy, dz)
        end)
        if ok and localPt then
            return math.abs(localPt.x) <= sx and math.abs(localPt.y) <= sy and math.abs(localPt.z) <= sz
        end
    end
    return math.abs(dx) <= sx and math.abs(dy) <= sy and math.abs(dz) <= sz
end

local function isPointInStagingSpotWithPadding(spot, wx, wy, wz, pad)
    if not spot or not spot.pos or not spot.scl then return false end
    local he = getStagingSpotHalfExtents(spot)
    if not he then return false end
    local p = pad or 0
    local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
    local sx, sy, sz = he[1] + p, he[2] + p, he[3] + p
    local dx, dy, dz = wx - px, wy - py, wz - pz
    if spot.rot and spot.rot[4] then
        local ok, localPt = pcall(function()
            local r = spot.rot
            local invQ = quat(-(r[1] or 0), -(r[2] or 0), -(r[3] or 0), r[4] or 1)
            return invQ * vec3(dx, dy, dz)
        end)
        if ok and localPt then
            return math.abs(localPt.x) <= sx and math.abs(localPt.y) <= sy and math.abs(localPt.z) <= sz
        end
    end
    return math.abs(dx) <= sx and math.abs(dy) <= sy and math.abs(dz) <= sz
end

function M.loadPlayerStagingSpot()
    local levelPath = core_levels.getLevelByName(getCurrentLevelIdentifier())
    if not levelPath then return nil end
    local sitesPath = levelPath.misFilePath .. "/competitiveRaceAI.sites.json"
    local sitesData = jsonReadFile(sitesPath)
    if not sitesData or not sitesData.parkingSpots then return nil end
    local spotName = getPlayerStagingSpotNameForLevel()
    for _, spot in ipairs(sitesData.parkingSpots) do
        if spot.name == spotName then
            return { pos = spot.pos, rot = spot.rot, scl = spot.scl, name = spotName }
        end
    end
    return nil
end

function M.isPlayerInStagingSpot(spot)
    if not spot or not spot.pos or not spot.scl then return false end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return false end
    local pos = playerVeh:getPosition()
    return isPointInStagingSpot(spot, pos.x, pos.y, pos.z)
end

local function isPlayerInTrackParkingCommitSpot(spot)
    if not spot or not spot.pos or not spot.scl then return false end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return false end
    local pos = playerVeh:getPosition()
    return isPointInStagingSpotWithPadding(spot, pos.x, pos.y, pos.z, TRACK_GRID_PARKING_COMMIT_PADDING_M)
end

function M.isPlayerInTrackParkingCommitArea()
    if not mPlayerStagingSpot then return false end
    return isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot)
end

function M.clearPlayerStagingCornerMarkers()
    for _, obj in ipairs(mPlayerStagingCornerMarkers) do
        pcall(function()
            if obj and obj.delete then obj:delete() end
        end)
    end
    table.clear(mPlayerStagingCornerMarkers)
end

function M.showPlayerStagingCornerMarkers(spot)
    M.clearPlayerStagingCornerMarkers()
    if not spot or not spot.pos or not spot.scl then return end
    if not createObject or not scenetree then return end
    local he = getStagingSpotHalfExtents(spot)
    if not he then return end
    local sx, sy, sz = he[1], he[2], he[3]
    local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
    local spotQuat
    local xVec, yVec, zVec = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
    if spot.rot and spot.rot[4] then
        local ok, q = pcall(function()
            local r = spot.rot
            return quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1)
        end)
        if ok and q then
            spotQuat = q
            xVec = q * vec3(1, 0, 0)
            yVec = q * vec3(0, 1, 0)
            zVec = q * vec3(0, 0, 1)
        end
    end
    local corners = {
        { px - xVec.x*sx + yVec.x*sy, py - xVec.y*sx + yVec.y*sy, pz - xVec.z*sx + yVec.z*sy },
        { px + xVec.x*sx + yVec.x*sy, py + xVec.y*sx + yVec.y*sy, pz + xVec.z*sx + yVec.z*sy },
        { px + xVec.x*sx - yVec.x*sy, py + xVec.y*sx - yVec.y*sy, pz + xVec.z*sx - yVec.z*sy },
        { px - xVec.x*sx - yVec.x*sy, py - xVec.y*sx - yVec.y*sy, pz - xVec.z*sx - yVec.z*sy },
    }
    local cornerZDeg = { 90, 180, 270, 0 }
    local markerScale = math.min(spot.scl[1] or 3, spot.scl[2] or 6) * 0.2
    if markerScale < 0.15 then markerScale = 0.15 end
    if markerScale > 1.5 then markerScale = 1.5 end
    local baseName = "freeroamTrackFlow_stageCorner_" .. tostring(os and os.time and os.time() or 0) .. "_"
    for i, c in ipairs(corners) do
        local ok, marker = pcall(function()
            local m = createObject("TSStatic")
            if not m then return nil end
            m.shapeName = "art/shapes/interface/position_marker.dae"
            m.scale = vec3(markerScale, markerScale, markerScale)
            m.useInstanceRenderData = true
            m.canSave = false
            if ColorF and ColorF(1, 0.5, 0, 1) and (ColorF(1, 0.5, 0, 1):asLinear4F()) then
                m.instanceColor = ColorF(1, 0.5, 0, 1):asLinear4F()
            else
                m:setField("instanceColor", 0, "1 0.5 0 1")
            end
            local rot = spotQuat
            if quatFromEuler and rot then
                local cornerZ = quatFromEuler(0, 0, math.rad(cornerZDeg[i] or 0))
                rot = rot * cornerZ
            end
            if rot then
                m:setPosRot(c[1], c[2], c[3] + 0.1, rot.x, rot.y, rot.z, rot.w)
            else
                m:setPosRot(c[1], c[2], c[3] + 0.1, 0, 0, 0, 0)
            end
            m:registerObject(baseName .. i)
            return m
        end)
        if ok and marker then
            table.insert(mPlayerStagingCornerMarkers, marker)
        end
    end
end

function M.getPlayerStagingSpot()
    return mPlayerStagingSpot
end

function M.setPlayerStagingSpot(spot)
    mPlayerStagingSpot = spot
end

function M.setPlayerStagingSpotNil()
    mPlayerStagingSpot = nil
end

function M.ensurePlayerStagingSpotLoaded()
    if mPlayerStagingSpot then return end
    local spot = M.loadPlayerStagingSpot()
    if spot then
        M.setPlayerStagingSpot(spot)
    end
end

function M.raceAllowsAiSpawn(race)
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not race or not aiRacers or not aiRacers.getMergedConfigForRace then return false end
    local cfg = aiRacers.getMergedConfigForRace(race)
    if not cfg or cfg.enabled == false then return false end
    if race.spawnSameVehicleAsPlayer or cfg.spawnSameVehicleAsPlayer then return true end
    local n = race.aiCount or cfg.maxSpawnCount or cfg.aiCount
    if type(n) == "number" and n > 0 then return true end
    if type(cfg.vehiclePool) == "table" then return true end
    return false
end

function M.trackRaceForAi()
    local races = sess().races
    if not races or not races.track then return nil end
    if M.trackFlowState.useAltRoute and races.track.altRoute then
        return races.track.altRoute
    end
    return races.track
end

function M.isSanctionedCareerGoToRaceActive()
    return M.trackFlowState.sanctionedCareerGoToRaceActive == true
end

function M.isSanctionedRaceStagingUiActive()
    return mSanctionedParkingUiPhase ~= "hidden"
end

function M.raceUsesSanctionedParkingStaging(raceName)
    return raceName == M.TRACK_RACE_ID
end

function M.shouldBlockFreeroamStagingPractice(raceName)
    if not M.isSanctionedRaceStagingUiActive() then
        return false
    end
    return M.raceUsesSanctionedParkingStaging(raceName)
end

function M.resolveEffectiveStagingRace(raceName, race)
    if M.raceUsesSanctionedParkingStaging(raceName) then
        return M.trackRaceForAi() or race
    end
    return race
end

function M.resolveStagingHudTotalLaps(raceName, sess, hotlapRaceName, effectiveStagingRace, isLapRace)
    if sess.freeroamPracticeStaging then
        return 0
    end
    if hotlapRaceName == raceName then
        return 0
    end
    local base = isLapRace and M.getDisplayTotalLapsForRace(effectiveStagingRace) or 0
    if not M.isSanctionedCareerGoToRaceActive() then
        if M.raceUsesSanctionedParkingStaging(raceName) then
            return 0
        end
        return base
    end
    if M.raceUsesSanctionedParkingStaging(raceName) then
        local sr = gameplay_events_freContracts_sanctionedRacing
        local lc = sr and sr.getSanctionedOfferLapCount and sr.getSanctionedOfferLapCount()
        if lc and lc > 0 then
            return lc
        end
    end
    return base
end

function M.resolveRacingHudTotalLaps(mActiveRaceName, sess, effectiveRace, isLapRace)
    local totalLapsVal = isLapRace and M.getDisplayTotalLapsForRace(effectiveRace) or 0
    if sess.freeroamPracticeStaging then
        return 0
    end
    local sr = gameplay_events_freContracts_sanctionedRacing
    -- When track flow didn't arm suppressFrePayouts yet, avoid forcing 0 laps (hotlap-style HUD): use committed offer or race data.
    if M.raceUsesSanctionedParkingStaging(mActiveRaceName) and sr and not sr.shouldSuppressFrePayouts() then
        local lc = sr.getCommittedRacingSanctionedOfferLapCount and sr.getCommittedRacingSanctionedOfferLapCount(mActiveRaceName)
        if lc and lc > 0 then
            return lc
        end
        return totalLapsVal
    end
    return totalLapsVal
end

function M.setSanctionedCareerGoToRaceActive(v)
    M.trackFlowState.sanctionedCareerGoToRaceActive = v == true
end

function M.clearSanctionedCareerGoToRaceActive()
    M.trackFlowState.sanctionedCareerGoToRaceActive = false
end

function M.isRacingTeamProxyRaceActive()
    return M.trackFlowState.racingTeamProxyRaceActive == true
end

function M.isRacingTeamProxyRaceSessionActive()
    return M.trackFlowState.racingTeamProxyRaceSession == true
end

--- Sanctioned phone flow OR racing-team proxy staging (shared grid / countdown gates).
function M.isTrackGridCareerStagingGateActive()
    return M.trackFlowState.sanctionedCareerGoToRaceActive == true or M.trackFlowState.racingTeamProxyRaceActive == true
end

function M.clearRacingTeamProxyParkingState()
    M.trackFlowState.racingTeamProxyRaceActive = false
    M.trackFlowState.racingTeamProxyBusinessId = nil
    M.trackFlowState.racingTeamProxyFleetVehicleId = nil
    M.trackFlowState.racingTeamProxyAiPoolRefHp = nil
    M.trackFlowState.racingTeamProxyAiPoolMinHp = nil
    M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
    M.trackFlowState.racingTeamProxyAiDifficultyT = nil
    mRacingTeamProxyNextAttemptClock = nil
    mRacingTeamProxyStagingTeleportJobActive = false
    M.exitRacingTeamProxyStagingLoadingScreen()
    restoreRacingTeamProxySpectatorUiAfterMinimal()
end

--- Load-in failed (no opponents spawned): return player to pre-race position, end staging, keep the proxy armed for a retry.
function M.abortRacingTeamProxyStagingLoadIn(reason)
    if not M.trackFlowState.racingTeamProxyRaceActive then
        return
    end
    racingTeamProxyResetAiSpawnBookkeeping()
    local rbd = gameplay_raceBusinessDriver
    if rbd and rbd.hasPreRaceWorldState and rbd.hasPreRaceWorldState() and rbd.restorePreRaceWorldState then
        pcall(function() rbd.restorePreRaceWorldState() end)
    end
    M.trackFlowState.inTrackFlowContext = false
    M.clearRacingTeamProxyParkingState()
    gameplay_events_freeroam_utils.displayMessage("Failed to load opponents. Try again.", 5)
end

--- Call when track race starts (beginFreeroamRace): parking proxy ends, session cleanup runs at race exit.
function M.onTrackRaceBeganFromRacingTeamProxy()
    if not M.trackFlowState.racingTeamProxyRaceActive then
        return
    end
    local bid = M.trackFlowState.racingTeamProxyBusinessId
    M.relayRacingTeamProxyOverlay({
        visible = true,
        businessId = bid and tostring(bid) or "",
        inRace = true,
        playerTeleportedToTeamCar = true,
    })
    refreshProxySpectatorUiIfMinimal()
    M.trackFlowState.racingTeamProxyRaceSession = true
    M.trackFlowState.racingTeamProxySessionBusinessId = M.trackFlowState.racingTeamProxyBusinessId
    M.trackFlowState.racingTeamProxySessionFleetVehicleId = M.trackFlowState.racingTeamProxyFleetVehicleId
    M.trackFlowState.racingTeamProxyRaceActive = false
    M.trackFlowState.racingTeamProxyBusinessId = nil
    M.trackFlowState.racingTeamProxyFleetVehicleId = nil
    M.trackFlowState.racingTeamProxyAiPoolRefHp = nil
    M.trackFlowState.racingTeamProxyAiPoolMinHp = nil
    M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
    M.trackFlowState.racingTeamProxyAiDifficultyT = nil
end

--- Returns { businessId, fleetVehicleId } once, then clears session markers (for post-race cleanup).
function M.takeRacingTeamProxyRaceSessionCleanup()
    if not M.trackFlowState.racingTeamProxyRaceSession then
        return nil
    end
    local out = {
        businessId = M.trackFlowState.racingTeamProxySessionBusinessId,
        fleetVehicleId = M.trackFlowState.racingTeamProxySessionFleetVehicleId,
    }
    M.trackFlowState.racingTeamProxyRaceSession = false
    M.trackFlowState.racingTeamProxySessionBusinessId = nil
    M.trackFlowState.racingTeamProxySessionFleetVehicleId = nil
    M.relayRacingTeamProxyOverlay({ visible = false })
    return out
end

--- Read { businessId, fleetVehicleId } without consuming the proxy session (for deferred cinematic finish).
function M.getRacingTeamProxyRaceSessionSnapshot()
    if not M.trackFlowState.racingTeamProxyRaceSession then
        return nil
    end
    return {
        businessId = M.trackFlowState.racingTeamProxySessionBusinessId,
        fleetVehicleId = M.trackFlowState.racingTeamProxySessionFleetVehicleId,
    }
end

function M.getDisplayTotalLapsForRace(r)
    local fs = gameplay_events_freeroam_session
    if not (fs and fs.freeroamPracticeStaging) then
        local forced = tonumber(M.trackFlowState.sanctionedRaceLapCount)
        if forced and forced > 0 and r == M.trackRaceForAi() then
            local sr = gameplay_events_freContracts_sanctionedRacing
            if sr and sr.shouldSuppressFrePayouts and sr.shouldSuppressFrePayouts() then
                return math.floor(forced)
            end
        end
    end
    if not r then return 0 end
    local lc = tonumber(r.lapCount)
    if lc and lc > 0 then
        return math.floor(lc)
    end
    local rs = r.session
    local slc = rs and tonumber(rs.lapCount)
    if slc and slc > 0 then
        return math.floor(slc)
    end
    if r.hotlap then return 3 end
    if r.checkpointRoad then return 1 end
    return 0
end

function M.spawnedTrackAiCount()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not aiRacers.getSpawnedVehicleIds then return 0 end
    local ids = aiRacers.getSpawnedVehicleIds()
    if not ids then return 0 end
    return #ids
end

function M.resetTrackGridFlowFlags()
    mTrackGridParkingAiSpawnStarted = false
    mCompetitiveAwaitingAiSpawn = false
    mTrackGridAiSpawnWaitDeadline = nil
end

function M.cancelCompetitiveGridFlow()
    mCompetitiveCountdownCancel = true
    mCompetitiveCountdownJobActive = false
    M.resetTrackGridFlowFlags()
    if guihooks and guihooks.trigger then
        guihooks.trigger('ScenarioFlashMessageReset')
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
end

function M.clearSanctionedNavigateVisuals()
    M.clearPlayerStagingCornerMarkers()
    local gm = core_groundMarkers
    if not gm then
        local ok, mod = pcall(function() return require('core/groundMarkers') end)
        if ok then gm = mod end
    end
    if gm then
        if gm.resetAll then
            gm.resetAll()
        elseif gm.setPath then
            gm.setPath(nil)
        end
    end
end

function M.leaveTrackFlowAfterRace()
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
    M.relayRacingTeamProxyOverlay({ visible = false })
    M.trackFlowState.inTrackFlowContext = false
    M.clearSanctionedCareerGoToRaceActive()
    M.trackFlowState.sanctionedPoolRefPw = nil
    M.trackFlowState.sanctionedPoolRefHp = nil
    M.trackFlowState.sanctionedRaceLapCount = nil
    M.trackFlowState.useAltRoute = false
    M.trackFlowState.racingTeamProxyRaceSession = false
    M.trackFlowState.racingTeamProxySessionBusinessId = nil
    M.trackFlowState.racingTeamProxySessionFleetVehicleId = nil
    M.clearRacingTeamProxyParkingState()
    M.resetTrackGridFlowFlags()
    M.setPlayerStagingSpotNil()
    M.clearSanctionedNavigateVisuals()
end

function M.isVehicleEligibleForCompetitiveTrack(spawnedId)
    if career_modules_cheats and career_modules_cheats.isCheatsMode and career_modules_cheats.isCheatsMode() then return true end
    if not career_career or not career_career.isActive() then return true end
    local function checkId(id)
        if not id then return false end
        if career_modules_business_businessInventory then
            local b, v = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(id)
            if b and v then return true end
        end
        if career_modules_inventory then
            local invId = career_modules_inventory.getInventoryIdFromVehicleId(id)
            if invId then
                local vehicle = career_modules_inventory.getVehicles()[invId]
                if vehicle and not vehicle.loanType then return true end
            end
        end
        return false
    end
    if checkId(spawnedId) then return true end
    local currentId = be and be:getPlayerVehicleID(0)
    if currentId and currentId ~= spawnedId then
        if checkId(currentId) then return true end
    end
    return false
end

--- Racing-team proxy: start player engine and wait until GE/vehicle data looks ready before freeze + countdown.
local RACING_TEAM_PROXY_PRE_COUNTDOWN_MAX_SEC = 3.0
local RACING_TEAM_PROXY_PRE_COUNTDOWN_STEP_SEC = 0.1
local RACING_TEAM_PROXY_PRE_COUNTDOWN_MIN_SEC = 0.4

local function racingTeamProxyPreCountdownWait(job)
    if not M.isRacingTeamProxyRaceActive() then
        return
    end
    local pv = be and be:getPlayerVehicle(0)
    if pv and core_vehicleBridge and core_vehicleBridge.executeAction then
        pcall(function()
            core_vehicleBridge.executeAction(pv, "setIgnitionLevel", 3)
        end)
    end
    if pv and pv.queueLuaCommand then
        pcall(function()
            pv:queueLuaCommand("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end")
        end)
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    local elapsed = 0
    while elapsed < RACING_TEAM_PROXY_PRE_COUNTDOWN_MAX_SEC do
        if mCompetitiveCountdownCancel then
            return
        end
        local vehBundleOk = true
        if core_vehicle_manager and core_vehicle_manager.getPlayerVehicleData then
            local vd = core_vehicle_manager.getPlayerVehicleData()
            vehBundleOk = vd and vd.vdata ~= nil
        end
        local pwOk = false
        if aiRacers and aiRacers.getPlayerVehiclePwForStagingUi then
            local pw = select(1, aiRacers.getPlayerVehiclePwForStagingUi())
            pwOk = type(pw) == "number" and pw > 0
        elseif aiRacers and aiRacers.getPlayerVehiclePowerAndClass then
            local pw = select(1, aiRacers.getPlayerVehiclePowerAndClass())
            pwOk = type(pw) == "number" and pw > 0
        end
        if elapsed >= RACING_TEAM_PROXY_PRE_COUNTDOWN_MIN_SEC and vehBundleOk and pwOk then
            job.sleep(0.2)
            return
        end
        job.sleep(RACING_TEAM_PROXY_PRE_COUNTDOWN_STEP_SEC)
        elapsed = elapsed + RACING_TEAM_PROXY_PRE_COUNTDOWN_STEP_SEC
    end
end

local function getVehicleSpeedMph(vehId)
    local speedUnit = sess().speedUnit
    if not vehId or not be or not be.getObjectVelocityXYZ then return 0 end
    local a, b, c = be:getObjectVelocityXYZ(vehId)
    if type(a) == "number" and type(b) == "number" and type(c) == "number" then
        return math.sqrt(a * a + b * b + c * c) * speedUnit
    end
    if type(a) == "number" then
        return math.abs(a) * speedUnit
    end
    if a ~= nil and type(a.length) == "function" then
        return a:length() * speedUnit
    end
    return 0
end

function M.startCompetitiveTrackCountdownAndRace()
    if sess().mActiveRace then return false end
    if mCompetitiveCountdownJobActive then return false end
    if sess().staged ~= M.TRACK_RACE_ID then return false end
    if not M.trackFlowState.inTrackFlowContext then return false end
    if not M.isTrackGridCareerStagingGateActive() then return false end
    M.setPlayerStagingSpotNil()
    M.clearPlayerStagingCornerMarkers()
    if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
    mCompetitiveCountdownJobActive = true
    mCompetitiveCountdownCancel = false
    refreshProxySpectatorUiIfMinimal()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not core_jobsystem or not core_jobsystem.create then
        mCompetitiveCountdownJobActive = false
        if M.isRacingTeamProxyRaceActive() then
            local pv = be and be:getPlayerVehicle(0)
            if pv and core_vehicleBridge and core_vehicleBridge.executeAction then
                pcall(function()
                    core_vehicleBridge.executeAction(pv, "setIgnitionLevel", 3)
                end)
            end
        end
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
        local vid = be and be:getPlayerVehicleID(0)
        local races = sess().races
        if vid and races and races[M.TRACK_RACE_ID] then
            gameplay_events_freeroamEvents.beginFreeroamRace(M.TRACK_RACE_ID, vid)
            refreshProxySpectatorUiIfMinimal()
            return true
        end
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
        return false
    end
    core_jobsystem.create(function(job)
        if mCompetitiveCountdownCancel then
            mCompetitiveCountdownJobActive = false
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            return
        end
        racingTeamProxyPreCountdownWait(job)
        if mCompetitiveCountdownCancel then
            mCompetitiveCountdownJobActive = false
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            return
        end
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
        refreshProxySpectatorUiIfMinimal()
        if guihooks and guihooks.trigger then
            guihooks.trigger('ScenarioFlashMessageReset')
            guihooks.trigger('ScenarioFlashMessage', {{3, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')", true},
                {2, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown2')", true},
                {1, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown3')", true}})
        end
        job.sleep(3)
        if mCompetitiveCountdownCancel then
            mCompetitiveCountdownJobActive = false
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            if guihooks and guihooks.trigger then guihooks.trigger('ScenarioFlashMessageReset') end
            return
        end
        if guihooks and guihooks.trigger then
            guihooks.trigger('ScenarioFlashMessageReset')
            guihooks.trigger('ScenarioFlashMessage', {{"ui.scenarios.go", 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')", true}})
        end
        job.sleep(0.35)
        mCompetitiveCountdownJobActive = false
        if mCompetitiveCountdownCancel then
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            return
        end
        refreshProxySpectatorUiIfMinimal()
        local vid = be and be:getPlayerVehicleID(0)
        local races = sess().races
        if vid and races and races[M.TRACK_RACE_ID] then
            gameplay_events_freeroamEvents.beginFreeroamRace(M.TRACK_RACE_ID, vid)
        elseif aiRacers and aiRacers.setPlayerFreeze then
            aiRacers.setPlayerFreeze(false)
        end
    end)
    return true
end

--- poolReferenceHpOverride: optional player hp/kg for AI spawn when live read is unavailable (never catalog crank HP).
function M.prepareFreeroamAiForTrack(poolReferenceHpOverride, deferCountdown)
    local races = sess().races
    if not races then
        sess().races = gameplay_events_freeroam_utils.loadRaceData()
        races = sess().races
    end
    local raceForAi = M.trackRaceForAi()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not raceForAi or not M.raceAllowsAiSpawn(raceForAi) then return end
    if sess().mActiveRace and sess().timerActive then return end
    if mCompetitiveAwaitingAiSpawn then return end
    -- Always clear any prior grid AI before spawning. Skipping clear when spawnedTrackAiCount() > 0 caused
    -- back-to-back racing-team proxy staging to reuse stale bookkeeping and skip a fresh spawn.
    if aiRacers.clearSpawned then aiRacers.clearSpawned() end
    mTrackGridParkingAiSpawnStarted = true
    mCompetitiveAwaitingAiSpawn = true
    mTrackGridAiSpawnWaitDeadline = os.time() + TRACK_GRID_AI_SPAWN_WAIT_SEC
    local refHp = type(poolReferenceHpOverride) == "number" and poolReferenceHpOverride > 0 and poolReferenceHpOverride or nil
    if not refHp and type(M.trackFlowState.sanctionedPoolRefPw) == "number" and M.trackFlowState.sanctionedPoolRefPw > 0 then
        refHp = M.trackFlowState.sanctionedPoolRefPw
    end
    if not refHp and type(M.trackFlowState.sanctionedPoolRefHp) == "number" and M.trackFlowState.sanctionedPoolRefHp > 0 then
        refHp = M.trackFlowState.sanctionedPoolRefHp
    end
    M.trackFlowState.sanctionedPoolRefPw = nil
    M.trackFlowState.sanctionedPoolRefHp = nil
    if not refHp and gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHp then
        refHp = gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHp()
    end
    local refHpMin = nil
    if type(M.trackFlowState.racingTeamProxyAiPoolMinHp) == "number" and M.trackFlowState.racingTeamProxyAiPoolMinHp > 0 then
        refHpMin = M.trackFlowState.racingTeamProxyAiPoolMinHp
    end
    M.trackFlowState.racingTeamProxyAiPoolMinHp = nil
    if not refHpMin and gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHpMin then
        refHpMin = gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHpMin()
    end
    local sanctionedSpawnCtx = nil
    if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getAiSpawnSanctionedContext then
        sanctionedSpawnCtx = gameplay_events_freContracts_sanctionedRacing.getAiSpawnSanctionedContext()
    end
    local rematchLineup = nil
    if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getRematchAiLineupSnapshot then
        rematchLineup = gameplay_events_freContracts_sanctionedRacing.getRematchAiLineupSnapshot()
    end
    local spawnCtx = sanctionedSpawnCtx
    if M.trackFlowState.racingTeamProxyAiPoolBracketOnly == true and type(refHp) == "number" and refHp > 0 and type(refHpMin) == "number" and refHpMin > 0 then
        spawnCtx = {}
        if type(sanctionedSpawnCtx) == "table" then
            for k, v in pairs(sanctionedSpawnCtx) do
                spawnCtx[k] = v
            end
        end
        spawnCtx.racingTeamProxyBracketOnlyAi = true
        spawnCtx.classPwMin = refHpMin
        spawnCtx.classPwMax = refHp
        spawnCtx.classHpMin = refHpMin
        spawnCtx.classHpMax = refHp
        local diffT = M.trackFlowState.racingTeamProxyAiDifficultyT
        if diffT ~= nil then
            spawnCtx.racingTeamProxyAiDifficultyT = diffT
        end
    end
    local function afterAiSpawnCommit()
        mCompetitiveAwaitingAiSpawn = false
        mTrackGridAiSpawnWaitDeadline = nil
        M.trackFlowState.racingTeamProxyAiPoolBracketOnly = false
        M.trackFlowState.racingTeamProxyAiDifficultyT = nil
        if deferCountdown then return end
        if sess().staged ~= M.TRACK_RACE_ID or sess().mActiveRace then return end
        if M.trackFlowState.inTrackFlowContext and M.isTrackGridCareerStagingGateActive() then
            M.startCompetitiveTrackCountdownAndRace()
        end
    end
    local rematchSpawned = false
    if type(rematchLineup) == "table" and #rematchLineup > 0 and aiRacers.spawnForStagingWithExactLineup then
        local spawned = tonumber(aiRacers.spawnForStagingWithExactLineup(M.TRACK_RACE_ID, raceForAi, M.TRACK_RACE_ID, rematchLineup)) or 0
        if spawned <= 0 then
            log("W", "competitiveTrackFlow", "Rematch lineup spawn returned 0; falling back to normal sanctioned spawn.")
        else
            rematchSpawned = true
            afterAiSpawnCommit()
        end
    end
    if rematchSpawned then
        return
    elseif aiRacers.spawnForStagingWithPlayerHp then
        aiRacers.spawnForStagingWithPlayerHp(M.TRACK_RACE_ID, raceForAi, M.TRACK_RACE_ID, function(spawned)
            local count = tonumber(spawned) or 0
            if count <= 0 then
                log("W", "competitiveTrackFlow", string.format("Sanctioned AI spawn returned %d; no generic fallback applied.", count))
            end
            afterAiSpawnCommit()
        end, refHp, refHpMin, spawnCtx)
    elseif aiRacers.spawnForStaging then
        local spawned = tonumber(aiRacers.spawnForStaging(M.TRACK_RACE_ID, raceForAi, M.TRACK_RACE_ID)) or 0
        if spawned <= 0 then
            log("W", "competitiveTrackFlow", "Sanctioned AI spawn returned 0.")
        end
        afterAiSpawnCommit()
    else
        afterAiSpawnCommit()
    end
end

function M.tryCommitTrackGridStaging(spawnVehId, opts)
    opts = type(opts) == "table" and opts or {}
    local skipAiPrereq = opts.skipAiPrereq == true
    if not M.isTrackGridCareerStagingGateActive() then return false end
    local raceName = M.TRACK_RACE_ID
    local races = sess().races
    if not races or not races[raceName] then return false end
    if not sess().staged and not sess().mActiveRace and mCompetitiveCountdownJobActive then
        mCompetitiveCountdownJobActive = false
        mCompetitiveCountdownCancel = false
    end
    if not mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot) then return false end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        gameplay_events_freeroam_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local vehicleSpeed = getVehicleSpeedMph(spawnVehId)
    if vehicleSpeed > TRACK_GRID_STAGE_STOP_MPH then
        return false
    end

    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) and not skipAiPrereq then
        if mCompetitiveAwaitingAiSpawn then
            return false
        end
        if not mTrackGridParkingAiSpawnStarted and M.spawnedTrackAiCount() == 0 then
            return false
        end
    end

    -- requestGameState can paint the world before Vue composites; re-arm team loading immediately before it for proxy staging.
    if M.trackFlowState.racingTeamProxyRaceActive then
        M.enterRacingTeamProxyStagingLoadingEarly()
    end

    sess().saveGameState = true
    core_gamestate.requestGameState()

    sess().mHotlap = nil
    gameplay_events_freeroamEvents.hideAllFreeroamAssets()
    sess().lapCount = 0

    local allTypesDisabled = false
    local disabledTypes = {}
    if career_economyAdjuster and races[raceName].type then
        local totalTypes = 0
        local disabledCount = 0
        for _, raceType in ipairs(races[raceName].type) do
            totalTypes = totalTypes + 1
            local multiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
            if multiplier == 0 then
                disabledCount = disabledCount + 1
                table.insert(disabledTypes, raceType)
            end
        end
        allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
    end

    if allTypesDisabled then
        local typesString = table.concat(disabledTypes, ", ")
        gameplay_events_freeroam_utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
        if M.trackFlowState.racingTeamProxyRaceActive then
            M.exitRacingTeamProxyStagingLoadingScreen()
        end
        return false
    end

    sess().staged = raceName
    sess().freeroamPracticeStaging = false
    local vehId = spawnVehId
    if career_career and career_career.isActive and career_career.isActive() then
        if career_modules_business_businessInventory and career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId then
            local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(spawnVehId)
            if businessId and vehicleId then
                vehId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
            elseif career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
                vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
        elseif career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
            vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
    end

    local race = races[raceName] or {}
    gameplay_events_freeroam_raceSession.setStagingSubjectId(vehId)
    if gameplay_events_freeroam_raceSession.raceHudApplies(race) then
        gameplay_events_freeroam_raceSession.showFreeroamRaceHud()
    else
        gameplay_events_freeroam_utils.displayStagedMessage(vehId, raceName)
    end
    gameplay_events_freeroam_utils.setActiveLight(raceName, "yellow")

    if not M.startCompetitiveTrackCountdownAndRace() then
        sess().staged = nil
        gameplay_events_freeroam_raceSession.setStagingSubjectId(nil)
        gameplay_events_freeroam_utils.setActiveLight(raceName, "red")
        gameplay_events_freeroam_raceSession.hideFreeroamRaceHud()
        gameplay_events_freeroamEvents.hideStagedFlashMessage()
        if M.trackFlowState.racingTeamProxyRaceActive then
            M.exitRacingTeamProxyStagingLoadingScreen()
        end
        return false
    end
    if M.trackFlowState.racingTeamProxyRaceActive then
        M.exitRacingTeamProxyStagingLoadingScreen()
    end
    refreshProxySpectatorUiIfMinimal()
    return true
end

local function pushSanctionedParkingGui()
    if not guihooks or not guihooks.trigger then return end
    if mSanctionedParkingUiPhase == "hidden" then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
        return
    end
    guihooks.trigger("SanctionedParkingStagingUi", {
        visible = true,
        payload = M.buildSanctionedParkingUiPayload(),
    })
end

function M.buildSanctionedParkingUiPayload()
    local sr = gameplay_events_freContracts_sanctionedRacing
    local pw, pwSource = nil, nil
    local ar = career_modules_competitiveRace_aiRacers
    if ar and ar.getPlayerVehiclePwForStagingUi then
        pw, pwSource = ar.getPlayerVehiclePwForStagingUi()
    elseif ar and ar.getPlayerVehiclePowerAndClass then
        pw = select(1, ar.getPlayerVehiclePowerAndClass())
        pwSource = "sync"
    end
    local out = {
        phase = mSanctionedParkingUiPhase,
        awaitingSpawn = mCompetitiveAwaitingAiSpawn,
        spawnedAiCount = M.spawnedTrackAiCount(),
        playerPw = pw,
        playerPwSource = pwSource,
    }
    if not sr or not sr.getOfferUiSnapshot then
        return out
    end
    local state = gameplay_events_freContracts_state.getState()
    local now = state and tonumber(state.simTime) or 0
    local snap = sr.getOfferUiSnapshot(now)
    if not snap then
        local raceForAiEarly = M.trackRaceForAi()
        out.requiresAiSpawn = raceForAiEarly and M.raceAllowsAiSpawn(raceForAiEarly) or false
        return out
    end
    out.raceLabel = snap.raceLabel
    out.stageNumber = tonumber(snap.stageNumber) or 1
    out.hpBracketBranch = snap.hpBracketBranch
    out.classPwMin = tonumber(snap.classPwMin)
    out.classPwMax = tonumber(snap.classPwMax)
    local raceClassSource = out.classPwMin or out.classPwMax
    local raceClassLabelFormatted = formatSanctionedClassWithBucket(snap.hpBracketLabel, snap.hpBracketBranch, raceClassSource)
    out.hpBracketLabel = raceClassLabelFormatted ~= "" and raceClassLabelFormatted or snap.hpBracketLabel
    out.raceClassLabel = out.hpBracketLabel
    if sr and sr.getSanctionedPwBracketLabelForPw and type(pw) == "number" and pw > 0 then
      local rawPlayerClass = sr.getSanctionedPwBracketLabelForPw(pw)
      local playerClassFormatted = formatSanctionedClassWithBucket(rawPlayerClass, snap.hpBracketBranch, pw)
      out.playerSanctionedClassLabel = playerClassFormatted ~= "" and playerClassFormatted or rawPlayerClass
    end
    out.lapCount = tonumber(snap.lapCount) or 0
    out.payoutFirst = snap.payoutFirst
    out.payoutSecond = snap.payoutSecond
    out.payoutThird = snap.payoutThird
    local raceForAi = M.trackRaceForAi()
    out.requiresAiSpawn = raceForAi and M.raceAllowsAiSpawn(raceForAi) or false
    return out
end

function M.sanctionedParkingAbortStaging()
    if mSanctionedParkingUiPhase == "hidden" then return end
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.clearSpawned then
        aiRacers.clearSpawned()
    end
    M.cancelCompetitiveGridFlow()
end

function M.clearSanctionedParkingStagingUi()
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
end

function M.sanctionedParkingStageAndSpawn()
    if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
    if mSanctionedParkingUiPhase ~= "prompt" then return false end
    if not mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot) then return false end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        gameplay_events_freeroam_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.setPlayerFreeze then
        aiRacers.setPlayerFreeze(true)
    end
    mSanctionedParkingUiPhase = "spawned_ready"
    M.prepareFreeroamAiForTrack(nil, true)
    pushSanctionedParkingGui()
    return true
end

function M.sanctionedParkingStartEvent()
    if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
    if mSanctionedParkingUiPhase ~= "spawned_ready" then return false end
    local pv = be:getPlayerVehicle(0)
    if not pv then return false end
    local vid = pv:getID()
    if not mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot) then return false end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        gameplay_events_freeroam_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
        if mCompetitiveAwaitingAiSpawn then
            gameplay_events_freeroam_utils.displayMessage("Wait for AI to finish loading.", 3)
            return false
        end
        if M.spawnedTrackAiCount() == 0 then
            gameplay_events_freeroam_utils.displayMessage("No AI on grid. Try staging again.", 4)
            return false
        end
    end
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
    local ok = M.tryCommitTrackGridStaging(vid, { skipAiPrereq = true })
    if not ok then
        mSanctionedParkingUiPhase = "spawned_ready"
        pushSanctionedParkingGui()
    end
    return ok
end

function M.beamngTrigger_trackBuilding(data, event)
    if not M.isVehicleEligibleForCompetitiveTrack(data.subjectID) then return end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if event == "enter" then
        if not aiRacers or not aiRacers.levelHasAiRacingConfig or not aiRacers.levelHasAiRacingConfig() then return end
        M.trackFlowState.inTrackFlowContext = true
        M.ensurePlayerStagingSpotLoaded()
        sess().saveGameState = true
        core_gamestate.requestGameState()
        local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
        local bc = career_modules_business_businessComputer
        if levelId and bc and bc.findProxyDriverRaceRequestForLevel then
            local req, bid = bc.findProxyDriverRaceRequestForLevel(levelId)
            if req and bid and req.racingTeamProxyRace and not M.trackFlowState.sanctionedCareerGoToRaceActive then
                M.trackFlowState.racingTeamProxyRaceActive = true
                M.trackFlowState.racingTeamProxyBusinessId = bid
                M.trackFlowState.racingTeamProxyFleetVehicleId = tonumber(req.fleetVehicleId) or req.fleetVehicleId
                syncRacingTeamProxyBracketFromRequest(req)
                local lc = tonumber(req.lapCount)
                if lc and lc > 0 then
                    M.trackFlowState.sanctionedRaceLapCount = lc
                end
                local rt = req.raceRouteType
                if type(rt) == "string" and rt:lower() == "alt" then
                    M.trackFlowState.useAltRoute = true
                end
            end
        end
    elseif event == "exit" then
        if not sess().mActiveRace then
            M.trackFlowState.inTrackFlowContext = false
            M.setPlayerStagingSpotNil()
            if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
            if not M.trackFlowState.racingTeamProxyRaceSession then
                M.clearRacingTeamProxyParkingState()
                M.sanctionedParkingAbortStaging()
            end
        end
    end
end

function M.onUpdateRacingTeamProxyParkingLoop()
    if not M.trackFlowState.racingTeamProxyRaceActive then
        return
    end
    if M.trackFlowState.sanctionedCareerGoToRaceActive then
        return
    end
    if not M.trackFlowState.inTrackFlowContext then
        return
    end
    local s = sess()
    if s.mActiveRace or s.staged or mCompetitiveCountdownJobActive then
        return
    end

    local clk = (os and os.clock) and os.clock() or 0
    if mRacingTeamProxyNextAttemptClock and (clk - mRacingTeamProxyNextAttemptClock) < 0.35 then
        return
    end
    mRacingTeamProxyNextAttemptClock = clk

    local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
    local bc = career_modules_business_businessComputer
    if not levelId or not bc or not bc.findProxyDriverRaceRequestForLevel then
        return
    end
    local req, businessId = bc.findProxyDriverRaceRequestForLevel(levelId)
    if not req or not businessId then
        M.clearRacingTeamProxyParkingState()
        return
    end

    M.ensurePlayerStagingSpotLoaded()
    if not mPlayerStagingSpot then
        return
    end

    local bid = M.trackFlowState.racingTeamProxyBusinessId
    local fid = M.trackFlowState.racingTeamProxyFleetVehicleId
    if not bid or not fid then
        return
    end

    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        return
    end

    local inv = career_modules_business_businessInventory
    if not inv or not inv.getBusinessVehicleFromSpawnedId or not inv.teleportSpawnedBusinessVehicleToSpot or not inv.getSpawnedVehicleId then
        return
    end

    local pv = be:getPlayerVehicle(0)
    if not pv then
        return
    end
    local vid = pv:getID()

    local bMatch, vMatch = inv.getBusinessVehicleFromSpawnedId(vid)
    local function idEq(a, b)
        return (tonumber(a) or a) == (tonumber(b) or b) or tostring(a) == tostring(b)
    end
    local inTeamCar = bMatch and vMatch and idEq(bMatch, bid) and idEq(vMatch, fid)

    local rbd = gameplay_raceBusinessDriver
    if not inTeamCar then
        if mRacingTeamProxyStagingTeleportJobActive then
            return
        end
        if not M.isPlayerInTrackParkingCommitArea() then
            return
        end
        if getVehicleSpeedMph(vid) > TRACK_GRID_STAGE_STOP_MPH then
            return
        end
        if rbd and rbd.hasPreRaceWorldState and not rbd.hasPreRaceWorldState() and rbd.savePreRaceWorldState then
            rbd.savePreRaceWorldState()
        end
        local useStagingOverlay = racingTeamProxyUseTeamLoadingOverlay()
        local function runProxyStagingTeleport()
            local okSpot = inv.teleportSpawnedBusinessVehicleToSpot(bid, fid, mPlayerStagingSpot)
            if okSpot then
                local teamVid = inv.getSpawnedVehicleId(bid, fid)
                local teamObj = teamVid and be:getObjectByID(teamVid)
                if teamObj and be.enterVehicle then
                    be:enterVehicle(0, teamObj)
                end
                M.relayRacingTeamProxyOverlay({
                    visible = true,
                    businessId = bid and tostring(bid) or "",
                    inRace = false,
                    playerTeleportedToTeamCar = true,
                })
                refreshProxySpectatorUiIfMinimal()
            end
            return okSpot == true
        end
        -- Racing-team proxy only: loading overlay stays up through teleport + AI spawn (same tick never paints; yield first).
        if useStagingOverlay and core_jobsystem and core_jobsystem.create then
            mRacingTeamProxyStagingTeleportJobActive = true
            M.enterRacingTeamProxyStagingLoadingEarly()
            core_jobsystem.create(function(job)
                job.sleep(RACING_TEAM_PROXY_TEAM_LOADING_PAINT_DELAY_SEC)
                local teleportedOk = false
                local ok, err = pcall(function()
                    teleportedOk = runProxyStagingTeleport()
                end)
                if not ok and log then
                    log("E", "competitiveTrackFlow", "racing team proxy staging teleport: " .. tostring(err))
                end
                if teleportedOk then
                    pcall(function()
                        racingTeamProxyRunStagingTailAfterPlayerInTeamCar(job)
                    end)
                end
                refreshProxySpectatorUiIfMinimal()
                mRacingTeamProxyStagingTeleportJobActive = false
                mRacingTeamProxyNextAttemptClock = nil
                M.onUpdateRacingTeamProxyParkingLoop()
            end)
            return
        end
        runProxyStagingTeleport()
        refreshProxySpectatorUiIfMinimal()
        mRacingTeamProxyNextAttemptClock = nil
        M.onUpdateRacingTeamProxyParkingLoop()
        return
    end

    if mRacingTeamProxyStagingTeleportJobActive then
        return
    end

    if not M.isPlayerInTrackParkingCommitArea() then
        return
    end
    if getVehicleSpeedMph(vid) > TRACK_GRID_STAGE_STOP_MPH then
        return
    end

    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
        if not mTrackGridParkingAiSpawnStarted and M.spawnedTrackAiCount() == 0 then
            local refPw = nil
            if type(M.trackFlowState.racingTeamProxyAiPoolRefHp) == "number" and M.trackFlowState.racingTeamProxyAiPoolRefHp > 0 then
                refPw = M.trackFlowState.racingTeamProxyAiPoolRefHp
            elseif career_modules_competitiveRace_aiRacers then
                local ar = career_modules_competitiveRace_aiRacers
                if ar.getPlayerVehiclePwForStagingUi then
                    refPw = select(1, ar.getPlayerVehiclePwForStagingUi())
                elseif ar.getPlayerVehiclePowerAndClass then
                    refPw = select(1, ar.getPlayerVehiclePowerAndClass())
                end
            end
            M.prepareFreeroamAiForTrack(refPw, true)
            return
        end
        if mCompetitiveAwaitingAiSpawn then
            return
        end
        if M.spawnedTrackAiCount() == 0 then
            return
        end
    end

    M.tryCommitTrackGridStaging(vid, { skipAiPrereq = true })
end

--- Racing team: from business computer while proxy is armed — spawn fleet car at player_stage_track, enter vehicle, then continue grid/AI flow (same as parking loop tail).
function M.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
    local rf = racingTeamRaceFlowMod()
    if not rf or not rf.getProxyDriverRaceRequest then
        M.exitRacingTeamProxyStagingLoadingScreen()
        return { ok = false, err = "no_proxy_flow" }
    end
    if not businessId then
        M.exitRacingTeamProxyStagingLoadingScreen()
        return { ok = false, err = "no_business" }
    end
    local req = rf.getProxyDriverRaceRequest(businessId)
    if not req or not req.racingTeamProxyRace then
        M.exitRacingTeamProxyStagingLoadingScreen()
        return { ok = false, err = "no_proxy_request" }
    end
    if M.trackFlowState.sanctionedCareerGoToRaceActive then
        M.exitRacingTeamProxyStagingLoadingScreen()
        return { ok = false, err = "sanctioned_phone_active" }
    end
    local s = sess()
    if s.mActiveRace or s.staged or mCompetitiveCountdownJobActive then
        M.exitRacingTeamProxyStagingLoadingScreen()
        return { ok = false, err = "race_or_staging_active" }
    end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        M.exitRacingTeamProxyStagingLoadingScreen()
        return { ok = false, err = "in_pursuit" }
    end

    -- Team loading overlay for remaining work: requestGameState, staging spot, teleport (matches spectate preflight).
    M.enterRacingTeamProxyStagingLoadingEarly()

    M.resetTrackGridFlowFlags()

    local bid = tonumber(businessId) or businessId
    local fid = tonumber(req.fleetVehicleId) or req.fleetVehicleId
    M.trackFlowState.racingTeamProxyRaceActive = true
    M.trackFlowState.racingTeamProxyBusinessId = bid
    M.trackFlowState.racingTeamProxyFleetVehicleId = fid
    local lc = tonumber(req.lapCount)
    if lc and lc > 0 then
        M.trackFlowState.sanctionedRaceLapCount = lc
    else
        M.trackFlowState.sanctionedRaceLapCount = nil
    end
    local rrt = req.raceRouteType
    M.trackFlowState.useAltRoute = type(rrt) == "string" and rrt:lower() == "alt"
    syncRacingTeamProxyBracketFromRequest(req)

    M.trackFlowState.inTrackFlowContext = true
    s.saveGameState = true
    if core_gamestate and core_gamestate.requestGameState then
        core_gamestate.requestGameState()
    end
    if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
            job.sleep(0.1)
            refreshProxySpectatorUiIfMinimal()
            job.sleep(0.2)
            refreshProxySpectatorUiIfMinimal()
        end)
    end

    M.ensurePlayerStagingSpotLoaded()
    if not mPlayerStagingSpot then
        M.exitRacingTeamProxyStagingLoadingScreen()
        M.clearRacingTeamProxyParkingState()
        M.trackFlowState.inTrackFlowContext = false
        return { ok = false, err = "no_staging_spot" }
    end

    local inv = career_modules_business_businessInventory
    if not inv or not inv.teleportSpawnedBusinessVehicleToSpot or not inv.getSpawnedVehicleId then
        M.exitRacingTeamProxyStagingLoadingScreen()
        M.clearRacingTeamProxyParkingState()
        M.trackFlowState.inTrackFlowContext = false
        return { ok = false, err = "no_inventory" }
    end

    local rbd = gameplay_raceBusinessDriver
    if rbd and rbd.hasPreRaceWorldState and not rbd.hasPreRaceWorldState() and rbd.savePreRaceWorldState then
        rbd.savePreRaceWorldState()
    end

    -- Teleport must finish before returning: the business-computer / Vue bridge uses the Lua return
    -- value. The old path returned { ok = true } while a jobsystem job still ran, so failures never
    -- reached the UI and the session looked "stuck" after a loading flash.

    if not inv.teleportSpawnedBusinessVehicleToSpot(bid, fid, mPlayerStagingSpot) then
        M.exitRacingTeamProxyStagingLoadingScreen()
        M.clearRacingTeamProxyParkingState()
        M.trackFlowState.inTrackFlowContext = false
        return { ok = false, err = "teleport_failed" }
    end

    local teamVid = inv.getSpawnedVehicleId(bid, fid)
    local teamObj = teamVid and be and be.getObjectByID and be:getObjectByID(teamVid)
    if not teamObj or not be.enterVehicle then
        M.exitRacingTeamProxyStagingLoadingScreen()
        M.clearRacingTeamProxyParkingState()
        M.trackFlowState.inTrackFlowContext = false
        return { ok = false, err = "enter_vehicle_failed" }
    end
    pcall(function()
        be:enterVehicle(0, teamObj)
    end)

    M.relayRacingTeamProxyOverlay({
        visible = true,
        businessId = bid and tostring(bid) or "",
        inRace = false,
        playerTeleportedToTeamCar = true,
    })
    refreshProxySpectatorUiIfMinimal()

    -- Team loading stays up until tryCommitTrackGridStaging succeeds (grid staged + countdown started).
    mRacingTeamProxyNextAttemptClock = nil
    if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
            pcall(function()
                racingTeamProxyRunStagingTailAfterPlayerInTeamCar(job)
            end)
            refreshProxySpectatorUiIfMinimal()
            mRacingTeamProxyNextAttemptClock = nil
            M.onUpdateRacingTeamProxyParkingLoop()
        end)
    else
        refreshProxySpectatorUiIfMinimal()
        M.onUpdateRacingTeamProxyParkingLoop()
    end
    return { ok = true }
end

function M.onUpdateParkingResolve()
    if mCompetitiveAwaitingAiSpawn and mTrackGridAiSpawnWaitDeadline and os.time() >= mTrackGridAiSpawnWaitDeadline then
        log("W", "competitiveTrackFlow", "AI spawn wait timed out; clearing await flag.")
        mCompetitiveAwaitingAiSpawn = false
        mTrackGridAiSpawnWaitDeadline = nil
        mTrackGridParkingAiSpawnStarted = false
    end
end

function M.onUpdateParkingLoop()
    if not sess().mActiveRace and M.trackFlowState.inTrackFlowContext and M.trackFlowState.sanctionedCareerGoToRaceActive and
        not sess().staged then
        M.ensurePlayerStagingSpotLoaded()
        if not mPlayerStagingSpot then return end
        local pv = be:getPlayerVehicle(0)
        local nowInParking = (pv and mPlayerStagingSpot and isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot)) or false
        if not nowInParking then
            if mSanctionedParkingUiPhase ~= "hidden" then
                M.sanctionedParkingAbortStaging()
            end
            return
        end
        if mSanctionedParkingUiPhase == "hidden" then
            mSanctionedParkingUiPhase = "prompt"
        end
        local clk = (os and os.clock) and os.clock() or 0
        if not mSanctionedParkingLiveRefreshClock or (clk - mSanctionedParkingLiveRefreshClock) >= SANCTIONED_PARKING_LIVE_HP_REFRESH_INTERVAL then
            mSanctionedParkingLiveRefreshClock = clk
            local ar = career_modules_competitiveRace_aiRacers
            if ar and ar.requestStagingUiLivePowerRefresh then
                ar.requestStagingUiLivePowerRefresh()
            end
        end
        if not mSanctionedParkingUiPushClock or (clk - mSanctionedParkingUiPushClock) >= SANCTIONED_PARKING_UI_PUSH_INTERVAL then
            mSanctionedParkingUiPushClock = clk
            pushSanctionedParkingGui()
        end
    end
end

function M.preloadAiPathsForTrack()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not aiRacers.preloadPathForRace then return end
    local levelId = getCurrentLevelIdentifier()
    local session = sess()
    local races = session and session.races
    if not levelId or not races or not races.track then return end
    aiRacers.preloadPathForRace(races.track)
    if races.track.altRoute and races.track.altRoute.checkpointRoad then
        aiRacers.preloadPathForRace(races.track.altRoute)
    end
end

function M.getCompetitiveAwaitingAiSpawn()
    return mCompetitiveAwaitingAiSpawn
end

function M.getCompetitiveCountdownJobActive()
    return mCompetitiveCountdownJobActive
end

function M.getTrackGridParkingAiSpawnStarted()
    return mTrackGridParkingAiSpawnStarted
end

function M.setTrackGridParkingAiSpawnStarted(v)
    mTrackGridParkingAiSpawnStarted = v
end

local function onExtensionLoaded()
end

M.onExtensionLoaded = onExtensionLoaded

return M
