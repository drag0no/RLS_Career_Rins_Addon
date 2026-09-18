-- AI racers for competitive (circuit) races.
-- Spawns AI vehicles at AI_stage_* spots on staging, then releases them on GO with script-path AI.

local M = {}

M.dependencies = { 'gameplay_events_freeroam_processRoad', 'gameplay_events_freeroam_competitiveTrackFlow' }

local CONFIG_DIR = "competitiveRace"
local CONFIG_FILENAME = "aiRacers.json"
local CONFIG_RACE_FILENAME = "aiRacingConfig.json"
local LEGACY_SITES_FILENAME = "competitiveRaceAI.sites.json"
local DEFAULT_CONFIG = {
    enabled = true,
    sitesFile = LEGACY_SITES_FILENAME,
    stagingPrefix = "AI_stage_",
    maxSpawnCount = 5,
    routeSpeed = 70,
    -- When false, AI speed is controlled by aggression only (like base game missions); when true, routeSpeed caps speed.
    useRouteSpeedLimit = false,
    aggressionMin = 0.6,
    aggressionMax = 0.75,
    avoidCars = "on",
    -- Circuit racing: 'off' lets AI use full track width and racing line; base game missions do not use driveInLane for race AI.
    driveInLane = "off",
    routeSpeedMode = "limit",
    useNavgraphPathfinding = true,
    -- Racing AI tuning (matches base game Race AI Parameters flowgraph). Skill 0-1: higher = tighter line, better avoidance.
    racerSkill = 0.8,
    useRacingParameters = true,
    -- Rubberband: AI eases off when ahead, pushes when behind (optional, like base missions).
    rubberBand = true,
    -- Script path width in metres at each node (prevents narrow path and corner clipping).
    scriptPathWidth = 2.5,
    navTargetReachDistance = 20,
    launchRecoveryGraceSeconds = 6,
    defaultVehiclePool = { "etk800", "sunburst", "200bx", "covet", "vivace", "grandmarshal" },
    recoveryEnabled = true,
    recoverySpeedThresholdMps = 1.0,
    recoveryStuckSeconds = 3.0,
    recoveryCooldownSeconds = 10.0,
    despawnWreckedEnabled = true,
    -- When false, no AI is despawned for stuck/wreck during race; only post-race delayed/clear despawn runs.
    -- Enabled by default so stuck/flipped AI are cleaned up mid-race instead of blocking the racing line on subsequent laps.
    despawnWreckedDuringRace = true,
    despawnUpsideDownSeconds = 8.0,
    despawnAfterRecoveries = 2,
    despawnTerminalStuckSeconds = 15.0,
    despawnAlwaysStuckSeconds = 25.0,
    delayedDespawnDefaultSeconds = 60.0,
    delayedDespawnStaggerSeconds = 4.0,
    startEngineOnSpawn = true,
    scriptBootstrapDistance = 6.0,
    -- AI pool: only spawn rows with hp/kg <= player hp/kg * (1 + aiPowerExceedCapPct). Legacy key filterPoolByPowerMeetOrExceed still accepted.
    filterPoolByPowerWeightMeetOrExceed = true,
    aiPowerExceedCapPct = 0.25,
    -- vehiclePool: AI configs with hp/kg in (player, player + this]; same scale as bracket pw (typ. ~0.04–0.09).
    aiPoolCloseAbovePw = 0.0617,
    -- On-screen ui_message after staging AI spawn (plan + hp/kg). Per-level aiRacers.json; false = off.
    aiSpawnDebugUi = false,
    -- Same payload to beamng.log (I/aiRacers) — works without ui_message; use for sanctioned P/W spawn diagnosis.
    aiSpawnDebugLog = false,
    -- overrideAI: multiplies lateral/longitudinal grip budget in raceplanAhead (1.0 = default, >1 = faster in corners).
    raceAccelScale = 1.15,
    raceThrottleKp = 1.12,
    -- driveToTarget: throttle pedal ramp (4 matches old state-based when raceAccelScale is set). Higher = on power sooner after braking.
    raceThrottleRateMult = 4,
    raceThrottleRecoveryMult = 1.9,
    -- driveUsingPath setParameters: higher = plan.targetSpeed follows planner faster (exit / straights).
    targetSpeedSmootherRate = 18,
    -- Wide-line racing (overrideAI): when lateral offset from plan exceeds start→end (m), blend traffic-limited speed back toward geometric cap (never above it).
    -- Bumped after .39 AI caution: recover more speed when already wide instead of settling in pack.
    raceWideLineTrafficBlend = 0.72,
    raceWideLineLateralStartM = 0.75,
    raceWideLineLateralEndM = 2.4,
    -- Soften understeer throttle lift when wide — keeps commitment on an alternate line.
    raceWideLineUndersteerRelax = 0.7,
    -- Corner line sacrifice (overrideAI): shift plan nodes outward in tight bends (curvature ~1/m). 0 = off.
    raceCornerLineLiftMaxM = 0.28,
    raceCornerCurvStart = 0.022,
    raceCornerCurvEnd = 0.10,
    raceCornerLineLiftScale = 1.0,
    -- overrideAI aggressive racing (traffic cap + alt plans + side push). Tuned post-.39 for more pass attempts.
    raceTrafficPassBlend = 0.78,
    raceClearanceScaleMin = 0.26,
    -- Wider margins + overrideAI hysteresis reduce lane flip-flop / indecision vs marginal wins.
    raceAltPlanSpeedMargin = 6.5,
    raceAltPlanTimeMargin = 3.8,
    raceAwarenessCoefScale = 0.95,
    raceBlockedAheadDistMax = 42,
    raceClearancePassMinGainM = 0.4,
    raceClearancePassTrafficEps = 0.3,
    -- overrideAI: < 1 scales racing brake from speed error (corners / traffic).
    raceBrakeGain = 0.9,
    -- Commit-corner racing
    raceCommitCorners = false,
    -- Safe revert: set raceCornerExitPush=false.
    raceCornerExitPush = true,
    raceCornerExitPushMinGain = 0.8,
    raceCornerExitPushOvershoot = 1.03,
    raceCornerExitPushRiseRate = 18,
    raceCornerExitPushSlipMax = 0.92,
    raceUndersteerSlipMin = 1.05,
    raceCornerGripUtil = 1.32,
    raceCornerPlanBoost = 1.06,
    raceCommitTargetOvershoot = 1.08,
    raceCommitSpeedFloorPct = 0.98,
    raceSlipTarget = 1.14,
    raceGripLiveRiseRate = 28,
    -- When non-empty, vehiclePool configs load from vehicles/<model>/<subdir>/<name>.pc (JSON stays basename-only). Empty = configs in model folder root.
    aiRaceConfigSubdir = "",
}

-- Racing-team proxy bracket spawn: soften AI max hp/kg vs player when read exists (same units as classPw*).
local PROXY_BRACKET_SOFT_PW_BELOW_PLAYER = 0.0265

local mSpawnedAiVehicleIds = {}
-- Orphan safety net: every vehId we've ever spawned this "spawn epoch" (since last clearSpawned). Active
-- list entries can be removed without the physical vehicle being destroyed (e.g. be:getObjectByID returns
-- nil transiently during a hard crash). This set is iterated in clearSpawned as a final sweep so wrecks
-- from a prior race cannot survive into the next race. Only cleared by clearSpawned.
local mEverSpawnedAiVehicleIdsSweep = {} -- [vehId] = true
local mLastSpawnedAiLineupSnapshot = {}
local mPathCache = {}  -- racePathKey -> array of { x, y, z }
local mRecoveryStateByVehId = {} -- [vehId] = { stuckTime, cooldown }
local mRetiredUpsideDownByVehId = {} -- [vehId] = true
local mRecoveryMonitorEnabled = false
local mRecoveryCheckAccumulator = 0
local mActiveRaceForRecovery = nil
local mActiveLapCountForRecovery = 1
local mVehicleLaneIndexByVehId = {}  -- [vehId] = laneIndex (for recovery to re-use same lane path)
local mNavStateByVehId = {} -- [vehId] = { path, targetIndex, lapsRemaining, aggression, targetX, targetY, targetZ }
local mRecoveryGraceTimer = 0
--- Set false to re-enable mid-race stuck / flip-stop / despawn monitor in `M.onUpdate`.
local DISABLE_AI_RACE_RECOVERY_FOR_TEST = true
local mDelayedDespawnActive = false
local mDelayedDespawnWaiting = false
local mDelayedDespawnTimer = 0
local mDelayedDespawnStaggerSeconds = 4.0
local mPlayerUnfreezeAt = nil  -- os.clock() time when to unfreeze player after AI GO (avoids dt spikes)
local mDnfCallback = nil  -- called with vehId when an AI is despawned (DNF)
-- Cache for per-race AI config (aiRacingConfig.json byRace): [levelId] = { byRace = { pathKey -> overrides } }
local mRaceConfigCache = {}
local pendingPowerCallback = nil
local pendingPowerVehId = nil
local pendingPowerRequestGen = 0
local pendingPowerRequestDeadline = nil
local POWER_REQUEST_MAX_RETRIES = 20
local POWER_REQUEST_DEADLINE_SEC = 8
-- Forward declarations for helpers used before their definitions.
local cancelDelayedDespawn
local queueEngineStart

-- Random colors for AI (r g b a, 0-1; a=1). Applied same-frame after spawn so no visible change.
local AI_COLOR_PALETTE = {
    "0.9 0.1 0.1 1",   -- red
    "0.1 0.2 0.7 1",   -- blue
    "0.95 0.75 0.05 1", -- gold
    "0.1 0.65 0.2 1",  -- green
    "0.6 0.1 0.6 1",   -- purple
    "0.0 0.0 0.0 1",   -- black
    "0.85 0.4 0.0 1",  -- orange
    "0.2 0.8 0.9 1",   -- cyan
    "0.9 0.9 0.9 1",   -- white
    "0.4 0.25 0.1 1",  -- brown
    "0.7 0.0 0.0 1",   -- dark red
    "0.0 0.35 0.6 1",  -- navy
}

local function pickRandomAiColor()
    local idx = math.random(1, #AI_COLOR_PALETTE)
    return AI_COLOR_PALETTE[idx]
end

--- Apply base paint (slot 1) to a spawned AI only. Do not use core_vehicle_colors.setVehicleColor here: it calls
--- partmgmt.setConfigPaints, which mergeConfigs into getPlayerVehicle(0) and can repaint random parts on the player car.
local function applyAiBasePaintOnly(vehId, colorString)
    if not vehId or not colorString then
        return
    end
    local mgr = extensions.core_vehicle_manager
    if not mgr or not mgr.getVehicleData or not mgr.liveUpdateVehicleColors then
        return
    end
    local cvc = extensions.core_vehicle_colors
    local colorToTable = cvc and cvc.colorStringToColorTable
    if not colorToTable then
        return
    end
    local vd = mgr.getVehicleData(vehId)
    if not vd or not vd.config then
        return
    end
    vd.config.paints = vd.config.paints or {}
    local color = colorToTable(colorString)
    if not color then
        return
    end
    color[4] = color[4] * 2
    local paint = createVehiclePaint(
        { x = color[1], y = color[2], z = color[3], w = color[4] },
        { color[5], color[6], color[7], color[8] }
    )
    local index = 1
    vd.config.paints[index] = paint
    local veh = getObjectByID(vehId)
    if not veh then
        return
    end
    mgr.liveUpdateVehicleColors(vehId, veh, index, paint)
end

local function copyLineupSnapshot(list)
    local out = {}
    if type(list) ~= "table" then
        return out
    end
    for _, row in ipairs(list) do
        if type(row) == "table" and type(row.model) == "string" and type(row.config) == "string" then
            table.insert(out, {
                model = row.model,
                config = row.config,
                matchPw = tonumber(row.matchPw) or tonumber(row.powerHp) or nil,
            })
        end
    end
    return out
end

local function setLastSpawnedLineupSnapshot(list)
    mLastSpawnedAiLineupSnapshot = copyLineupSnapshot(list)
end

local function configKeyFromConfigPath(model, configPath)
    if type(model) ~= "string" or model == "" or type(configPath) ~= "string" or configPath == "" then
        return nil
    end
    local prefix = "vehicles/" .. model .. "/"
    if string.sub(configPath, 1, #prefix) ~= prefix then
        return nil
    end
    local tail = string.sub(configPath, #prefix + 1)
    if string.sub(tail, -3) == ".pc" then
        tail = string.sub(tail, 1, #tail - 3)
    end
    return tail ~= "" and tail or nil
end

local function aiSpawnDebugEnabled(cfg)
    return type(cfg) == "table" and (cfg.aiSpawnDebugUi == true or cfg.aiSpawnDebugLog == true)
end

-- Staging debug: set aiSpawnDebugUi and/or aiSpawnDebugLog in levels/<id>/gameplay/competitiveRace/aiRacers.json (merged via getMergedConfigForRace).
local function showAiSpawnDebugUi(cfg, lines)
    if not aiSpawnDebugEnabled(cfg) or type(lines) ~= "table" or #lines == 0 then
        return
    end
    local text = table.concat(lines, "\n")
    if cfg.aiSpawnDebugLog == true then
        local logText = text
        if #logText > 4500 then
            logText = logText:sub(1, 4500) .. "..."
        end
        pcall(function()
            log("I", "aiRacers", "[aiSpawnDebug]\n" .. logText)
        end)
    end
    if cfg.aiSpawnDebugUi == true and type(ui_message) == "function" then
        local uiText = text
        if #uiText > 1400 then
            uiText = uiText:sub(1, 1400) .. "..."
        end
        pcall(function()
            ui_message(uiText, 30, "AI spawn debug")
        end)
    end
end

local function shallowCopyDefaults(defaults, fromFile)
    local out = {}
    for k, v in pairs(defaults) do out[k] = v end
    if type(fromFile) == "table" then
        for k, v in pairs(fromFile) do out[k] = v end
    end
    return out
end

--- Copy vehiclePool tiers and prefix config keys with subdir/ for on-disk layout under each vehicle folder.
local function copyVehiclePoolWithConfigSubdir(vehiclePool, subdir)
    if type(vehiclePool) ~= "table" or type(subdir) ~= "string" or subdir == "" then
        return vehiclePool
    end
    local tiers = { "stock", "modified", "super", "open" }
    local out = {}
    for _, tier in ipairs(tiers) do
        local arr = vehiclePool[tier]
        if type(arr) == "table" then
            out[tier] = {}
            for _, row in ipairs(arr) do
                if type(row) == "table" then
                    local r = {}
                    for k, v in pairs(row) do
                        r[k] = v
                    end
                    if type(r.config) == "string" and r.config ~= "" and not string.find(r.config, "/", 1, true) then
                        r.config = subdir .. "/" .. r.config
                    end
                    table.insert(out[tier], r)
                end
            end
        end
    end
    return out
end

-- When JSON omits aiRaceConfigSubdir, fallback spawns still resolve .pc under this folder (not model-root default only).
local DEFAULT_AI_RACE_CONFIG_SUBDIR_FALLBACK = "rls_race_ai"

local function aiRaceConfigSubdirForFallbackSpawn(cfg)
    if type(cfg) == "table" and type(cfg.aiRaceConfigSubdir) == "string" and cfg.aiRaceConfigSubdir ~= "" then
        return cfg.aiRaceConfigSubdir
    end
    return DEFAULT_AI_RACE_CONFIG_SUBDIR_FALLBACK
end

-- Relative path under vehicles/<model>/ for spawn; rows already using "subdir/basename" are left unchanged.
local function poolConfigRelPathForSpawn(spec, modelKey, configKey, pathCfg)
    if type(configKey) ~= "string" or configKey == "" then
        return nil
    end
    if string.find(configKey, "/", 1, true) then
        return configKey
    end
    local sub = aiRaceConfigSubdirForFallbackSpawn(pathCfg)
    if type(sub) == "string" and sub ~= "" then
        return sub .. "/" .. configKey
    end
    return configKey
end

local function fillSpawnPlanCyclingRows(plan, rows, requestedCount)
    if type(plan) ~= "table" or type(rows) ~= "table" or #rows == 0 or type(requestedCount) ~= "number" then
        return
    end
    local n = #rows
    while #plan < requestedCount do
        local r = rows[((#plan) % n) + 1]
        table.insert(plan, { model = r.model, config = r.config, matchPw = r.pw })
    end
end

local function getCurrentLevelConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then
        return shallowCopyDefaults(DEFAULT_CONFIG, nil)
    end
    local configPath = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. CONFIG_FILENAME
    local fromFile = jsonReadFile(configPath)
    local cfg = shallowCopyDefaults(DEFAULT_CONFIG, fromFile)
    if type(cfg.defaultVehiclePool) ~= "table" or #cfg.defaultVehiclePool == 0 then
        cfg.defaultVehiclePool = DEFAULT_CONFIG.defaultVehiclePool
    end
    return cfg
end

-- Load aiRacingConfig.json (per-race overrides in byRace). Keys in byRace = getRacePathKey(race), e.g. "trackloop", "trackalt".
local function loadRaceConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return { byRace = {} } end
    if mRaceConfigCache[levelId] then return mRaceConfigCache[levelId] end
    local path = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. CONFIG_RACE_FILENAME
    local data = jsonReadFile(path)
    local result = { byRace = {} }
    if type(data) == "table" then
        if type(data.byRace) == "table" then result.byRace = data.byRace end
        if type(data.vehiclePool) == "table" then result.vehiclePool = data.vehiclePool end
        if data.aiRaceConfigSubdir ~= nil then
            result.aiRaceConfigSubdir = data.aiRaceConfigSubdir
        end
    end
    mRaceConfigCache[levelId] = result
    return result
end

-- True if the current level has aiRacingConfig.json with at least one byRace entry.
function M.levelHasAiRacingConfig()
    local rc = loadRaceConfig()
    return type(rc) == "table" and type(rc.byRace) == "table" and next(rc.byRace) ~= nil
end

local function getRacePathKey(race)
    if not race or not race.checkpointRoad then return nil end
    if type(race.checkpointRoad) == "string" then
        return race.checkpointRoad
    end
    if type(race.checkpointRoad) == "table" then
        -- Single-element array (e.g. ["trackloop"]) must match aiRacingConfig.byRace keys like "trackloop"
        if #race.checkpointRoad == 1 and type(race.checkpointRoad[1]) == "string" then
            return race.checkpointRoad[1]
        end
        return serialize(race.checkpointRoad)
    end
    return nil
end

-- Merged config for a race: level aiRacers.json + aiRacingConfig.byRace[pathKey] + race table (race_data) for backward compat.
-- Use this wherever we have a race and want AI settings (spawn, drive, recovery). pathKey = getRacePathKey(race), e.g. "trackloop" or "trackalt".
local function getMergedConfigForRace(race)
    local levelCfg = getCurrentLevelConfig()
    if not race then return levelCfg end
    local pathKey = getRacePathKey(race)
    if not pathKey or pathKey == "" then return levelCfg end
    local raceConfig = loadRaceConfig()
    local overrides = (raceConfig.byRace and raceConfig.byRace[pathKey]) or {}
    local merged = shallowCopyDefaults(levelCfg, overrides)
    -- Backward compat: race_data.json structure only. No tuning (state-based in overrideAI). No route speed, no rubberband here (rubberband later by XP).
    local raceKeys = {
        "spawnSameVehicleAsPlayer", "aiCount", "aiVehicles",
        "enabled", "maxSpawnCount", "driveInLane", "useNavgraphPathfinding",
        "scriptPathWidth", "scriptBootstrapDistance", "navTargetReachDistance",
        "launchRecoveryGraceSeconds", "startEngineOnSpawn", "recoveryEnabled", "recoverySpeedThresholdMps",
        "recoveryStuckSeconds", "recoveryCooldownSeconds", "despawnWreckedEnabled", "despawnWreckedDuringRace",
        "despawnUpsideDownSeconds", "despawnAfterRecoveries", "despawnTerminalStuckSeconds", "despawnAlwaysStuckSeconds",
        "delayedDespawnDefaultSeconds", "delayedDespawnStaggerSeconds",
        "filterPoolByPowerWeightMeetOrExceed", "filterPoolByPowerMeetOrExceed", "aiPowerExceedCapPct", "aiPoolCloseAbovePw", "aiPoolCloseAboveHp", "aiSpawnDebugUi", "aiSpawnDebugLog",
        "pathRoad",
        "raceAccelScale", "raceThrottleKp",
        "raceThrottleRateMult", "raceThrottleRecoveryMult", "targetSpeedSmootherRate",
        "raceWideLineTrafficBlend", "raceWideLineLateralStartM", "raceWideLineLateralEndM",
        "raceWideLineUndersteerRelax", "raceThrottleFloor", "raceHighSpeedThreshold", "raceHighSpeedThrottleFloor",
        "raceCornerLineLiftMaxM", "raceCornerCurvStart", "raceCornerCurvEnd", "raceCornerLineLiftScale",
        "raceTrafficPassBlend", "raceClearanceScaleMin", "raceAltPlanSpeedMargin", "raceAltPlanTimeMargin",
        "raceAwarenessCoefScale",
        "raceBlockedAheadDistMax", "raceClearancePassMinGainM", "raceClearancePassTrafficEps",
        "raceBrakeGain", "raceCornerGripUtil", "raceCornerPlanBoost", "raceCommitCorners", "raceCornerExitPush",
        "raceCornerExitPushMinGain", "raceCornerExitPushOvershoot", "raceCornerExitPushRiseRate", "raceCornerExitPushSlipMax", "raceUndersteerSlipMin",
        "raceGripLiveRiseRate", "raceCommitTargetOvershoot", "raceCommitSpeedFloorPct", "raceSlipTarget", "raceSlipGain", "raceFrictionMult"
    }
    for _, k in ipairs(raceKeys) do
        if race[k] ~= nil then merged[k] = race[k] end
    end
    if type(raceConfig.vehiclePool) == "table" then
        merged.vehiclePool = raceConfig.vehiclePool
    end
    if type(overrides.vehiclePool) == "table" then
        merged.vehiclePool = overrides.vehiclePool
    end
    if raceConfig.aiRaceConfigSubdir ~= nil then
        merged.aiRaceConfigSubdir = raceConfig.aiRaceConfigSubdir
    end
    if type(merged.vehiclePool) == "table" and type(merged.aiRaceConfigSubdir) == "string" and merged.aiRaceConfigSubdir ~= "" then
        merged.vehiclePool = copyVehiclePoolWithConfigSubdir(merged.vehiclePool, merged.aiRaceConfigSubdir)
    end
    merged.sanctioned = nil
    return merged
end

-- Get nodes from a DecalRoad by name (for AI path when pathRoad is set in aiRacingConfig). Does not touch processRoad; checkpoints stay on race.checkpointRoad.
local function getRoadNodesByName(roadName)
    if type(roadName) ~= "string" or roadName == "" then return nil end
    if not scenetree or not scenetree.findObject then return nil end
    local road = scenetree.findObject(roadName)
    if not road or road:getClassName() ~= "DecalRoad" then return nil end
    local nodeCount = 0
    if road.getNodeCount then nodeCount = road:getNodeCount() end
    if nodeCount <= 0 then return nil end
    local nodeTable = {}
    if road.getNodesTable then nodeTable = road:getNodesTable() or {} end
    local roadNodes = {}
    for i = 0, nodeCount - 1 do
        local pos = road:getNodePosition(i)
        if pos then
            local width = (nodeTable[i + 1] and nodeTable[i + 1][2]) or nil
            table.insert(roadNodes, { x = pos.x, y = pos.y, z = pos.z, width = width })
        end
    end
    return #roadNodes > 0 and roadNodes or nil
end

-- Build path from race checkpointRoad (uses processRoad). Call on level load. When pathRoad is set in aiRacingConfig.byRace, use that road for AI path only; checkpoints unchanged. When race has checkpointRoadLanes, also preloads one path per lane (lane road merged with main from first checkpoint).
function M.preloadPathForRace(race)
    local pr = gameplay_events_freeroam_processRoad
    if not pr then return end
    local pathKey = getRacePathKey(race)
    if not pathKey then return end
    if not mPathCache[pathKey] then
        local cfg = getMergedConfigForRace(race)
        local pathRoad = (cfg and type(cfg.pathRoad) == "string" and cfg.pathRoad ~= "") and cfg.pathRoad or nil
        local nodes = pathRoad and getRoadNodesByName(pathRoad) or pr.getRoadNodesFromRace(race)
        if nodes and #nodes > 0 then
            local path = {}
            for _, node in ipairs(nodes) do
                if node.x and node.y and node.z then
                    table.insert(path, { x = node.x, y = node.y, z = node.z })
                end
            end
            if #path > 0 then
                mPathCache[pathKey] = path
            end
        end
    end
    if race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table" and #race.checkpointRoadLanes > 0 then
        for laneIndex = 0, #race.checkpointRoadLanes - 1 do
            local lanePathKey = pathKey .. "_lane_" .. tostring(laneIndex)
            if not mPathCache[lanePathKey] then
                local laneNodes = pr.getRoadNodesFromRace(race, laneIndex)
                if laneNodes and #laneNodes > 0 then
                    local lanePath = {}
                    for _, node in ipairs(laneNodes) do
                        if node.x and node.y and node.z then
                            table.insert(lanePath, { x = node.x, y = node.y, z = node.z })
                        end
                    end
                    if #lanePath > 0 then
                        mPathCache[lanePathKey] = lanePath
                    end
                end
            end
        end
    end
end

-- Preload all race paths from race data (call from manager after loading race JSON).
function M.preloadPathsForRaces(racesById)
    if type(racesById) ~= "table" then return end
    for _, race in pairs(racesById) do
        if race and race.checkpointRoad then
            M.preloadPathForRace(race)
        end
    end
end

-- Load staging spots for the current level. Returns array of spots { name, pos, rot } or nil.
-- Tries CONFIG_DIR subdir first (e.g. levels/west_coast_usa/competitiveRace/competitiveRaceAI.sites.json), then level root.
local function loadStagingSpots()
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return nil end
    local cfg = getCurrentLevelConfig()
    local sitesFile = cfg.sitesFile or LEGACY_SITES_FILENAME
    local preferredPath = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. sitesFile
    local data = jsonReadFile(preferredPath)
    if not data or not data.parkingSpots or #data.parkingSpots == 0 then
        local fallbackPath = "levels/" .. levelId .. "/" .. sitesFile
        data = jsonReadFile(fallbackPath)
    end
    if not data or not data.parkingSpots or #data.parkingSpots == 0 then return nil end
    local prefix = cfg.stagingPrefix or "AI_stage_"
    local spots = {}
    for _, spot in ipairs(data.parkingSpots) do
        local name = spot and spot.name or ""
        if type(name) == "string" and name:sub(1, #prefix) == prefix then
            table.insert(spots, spot)
        end
    end
    table.sort(spots, function(a, b)
        local an = tonumber((a.name or ""):match("(%d+)$")) or math.huge
        local bn = tonumber((b.name or ""):match("(%d+)$")) or math.huge
        return an < bn
    end)
    return spots
end

local function getVehiclePoolForRace(raceName, race, facilityName, levelOrMergedCfg)
    local cfg = (type(levelOrMergedCfg) == "table" and levelOrMergedCfg) or getCurrentLevelConfig()
    local byRace = cfg.vehiclePoolByRace and cfg.vehiclePoolByRace[raceName]
    if type(byRace) == "table" and #byRace > 0 then return byRace end
    local byFacility = cfg.vehiclePoolByFacility and cfg.vehiclePoolByFacility[facilityName]
    if type(byFacility) == "table" and #byFacility > 0 then return byFacility end
    if type(race) == "table" and type(race.aiVehicles) == "table" and #race.aiVehicles > 0 then
        return race.aiVehicles
    end
    return cfg.defaultVehiclePool
end

-- HP class bands (same as CLASS_MAX_HP): D 0-160, C 161-370, B 371-600, A 601+.
local function getClassFromHp(power)
    if type(power) ~= "number" or power < 0 then return "D" end
    if power <= 160 then return "D" end
    if power <= 370 then return "C" end
    if power <= 600 then return "B" end
    return "A"
end

-- Legacy defaultVehiclePool tiers use D/C/B/A; player metric is hp/kg when structured vehiclePool is absent.
local function getDcbaClassFromPlayerPw(pw)
    if type(pw) ~= "number" or pw < 0 then return "D" end
    if pw <= 0.1433 then return "D" end
    if pw <= 0.2535 then return "C" end
    if pw <= 0.3858 then return "B" end
    return "A"
end

-- vehiclePool tiers by player hp/kg when cfg.vehiclePool is set (merged upward from this tier).
local STOCK_MAX_PW = 0.2535
local MODIFIED_MAX_PW = 0.3638
local SUPER_MAX_PW = 0.4520
-- Configs within this many HP of the player are preferred when picking from the pool (then by closest).
local CLOSE_HP_TOLERANCE = 25
local function getClassFromPwForVehiclePool(pw)
    if type(pw) ~= "number" or pw < 0 then return "stock" end
    if pw <= STOCK_MAX_PW then return "stock" end
    if pw <= MODIFIED_MAX_PW then return "modified" end
    if pw <= SUPER_MAX_PW then return "super" end
    return "open"
end

local function getClassFromHpForVehiclePool(power)
    return getClassFromPwForVehiclePool(power)
end

-- Pool for a given HP class. Uses cfg.vehiclePoolByHpClass[class] if set, else defaultVehiclePool.
local function getVehiclePoolForHpClass(cfg, class)
    if not cfg then return DEFAULT_CONFIG.defaultVehiclePool end
    local byClass = cfg.vehiclePoolByHpClass and cfg.vehiclePoolByHpClass[class]
    if type(byClass) == "table" and #byClass > 0 then return byClass end
    return cfg.defaultVehiclePool or DEFAULT_CONFIG.defaultVehiclePool
end

-- Power unit conversion. 1 mechanical HP = 745.7 W.
local WATTS_PER_HP = 745.7
local function powerWattsToHp(watts)
    local w = tonumber(watts)
    if not w or w < 0 then return nil end
    return w / WATTS_PER_HP
end

-- Vehicle Lua engine.maxPower (and UI activeObjectLua) often returns HP-scale numbers (~400); large values are SI watts.
-- Same >10000 threshold as getPowerHpFromConfig. Callbacks expect watts.
local function liveMaxPowerRawToWatts(raw)
    local r = tonumber(raw)
    if not r or r < 0 then return nil end
    if r == 0 then return 0 end
    if r > 10000 then return r end
    return r * WATTS_PER_HP
end

-- Extract power in HP from a config table. Uses top-level config["Power"] (like vehiclePerformance), then config.aggregates.Power.
-- Handles: number (if > 10000 assume watts and convert, else assume HP), or table { propulsionPowerCombined = watts } or { min, max }.
local function getPowerHpFromConfig(config)
    if not config then return nil end
    local p = config["Power"] or (config.aggregates and config.aggregates.Power)
    if type(p) == "number" then
        if p > 10000 then return p / WATTS_PER_HP end
        return p
    end
    if type(p) == "table" then
        local w = p.propulsionPowerCombined or p.max or p.min
        if type(w) == "number" then
            if w > 10000 then return w / WATTS_PER_HP end
            return w
        end
    end
    return nil
end

-- Weight in kg from a vehicle config table (catalog / getConfig).
local function getWeightKgFromConfig(config)
    if not config then return nil end
    local w = config.total_weight or (config.aggregates and config.aggregates.total_weight)
    return tonumber(w)
end

-- hp/kg = mechanical HP ÷ curb weight (kg).
local function hpPerKgFromHpAndWeightKg(hp, weightKg)
    local h = tonumber(hp)
    local wkg = tonumber(weightKg)
    if not h or h <= 0 or not wkg or wkg <= 0 then return nil end
    return h / wkg
end

-- Legacy aiRacingConfig used fake band ints (200,250,…) on peakHp; map to representative hp/kg when no catalog/name tier.
local LEGACY_PEAKHP_BAND_TO_PW = {
    [200] = 0.2205, [250] = 0.2866, [300] = 0.3307, [350] = 0.3968, [500] = 0.4850,
}

--- Integer tier from config basename: _pw250, pw300, 200pw (e.g. 250 → match player round(pw*1000) nearest by |T-P| when catalog missing).
local function parseFilenameTierInt(configKey)
    if type(configKey) ~= "string" or configKey == "" then
        return nil
    end
    local nStr = configKey:match("_pw(%d%d%d)") or configKey:match("pw(%d%d%d)") or configKey:match("(%d%d%d)pw")
    local v = tonumber(nStr)
    if v and v >= 50 and v <= 2000 then
        return math.floor(v + 0.5)
    end
    return nil
end

-- Match hp/kg for pool rows: **catalog (getConfig) first**; JSON `peakPw` is ignored for matching; legacy peakHp band; filename tier ÷1000.
local function getMatchPwForPoolEntry(entry, model, config)
    if type(model) == "string" and type(config) == "string" and core_vehicles and core_vehicles.getConfig then
        local cfgTbl = core_vehicles.getConfig(model, config)
        local hp = getPowerHpFromConfig(cfgTbl)
        local wkg = getWeightKgFromConfig(cfgTbl)
        local catalogPw = hpPerKgFromHpAndWeightKg(hp, wkg)
        if type(catalogPw) == "number" and catalogPw > 0 then
            return catalogPw
        end
    end
    if type(entry) == "table" then
        local leg = tonumber(entry.peakHp) or tonumber(entry.hp) or tonumber(entry.powerHp)
        if leg and leg > 0 then
            local band = LEGACY_PEAKHP_BAND_TO_PW[math.floor(leg + 0.5)]
            if band then
                return band
            end
            if leg < 2 and leg > 0 then
                return leg
            end
        end
    end
    if type(config) == "string" then
        local tier = parseFilenameTierInt(config)
        if tier then
            return tier / 1000
        end
    end
    return nil
end

-- Power for a vehicle model from config (no spawn). Returns power in HP, or nil.
-- When configKey is provided (e.g. "AI_Pessima_stock"), uses that config; otherwise default_pc.
local function getPowerForModelConfig(modelKey, configKey)
    if not modelKey or type(modelKey) ~= "string" then return nil end
    if not core_vehicles or not core_vehicles.getModel or not core_vehicles.getConfig then return nil end
    local data = core_vehicles.getModel(modelKey)
    if not data or not data.model or not data.configs then return nil end
    if not configKey or type(configKey) ~= "string" or configKey == "" then
        configKey = data.model.default_pc
        if not configKey then
            for k, _ in pairs(data.configs) do configKey = k break end
        end
    end
    if not configKey then return nil end
    local config = core_vehicles.getConfig(modelKey, configKey)
    return getPowerHpFromConfig(config)
end

-- Alias: pool "power" for sanctioned matching is hp/kg (see getMatchPwForPoolEntry).
local function getPowerHpForPoolEntry(entry, model, config)
    return getMatchPwForPoolEntry(entry, model, config)
end

local STAGING_DEBUG_AI_SLOTS = 4

local function stagingDebugLivePlayerLine(powerDbg)
    if type(powerDbg.playerPwDbg) == "number" and powerDbg.playerPwDbg > 0 then
        return string.format("live player hp/kg = %.4f", powerDbg.playerPwDbg)
    end
    return "live player hp/kg = n/a"
end

local function stagingDebugHpForPlanSlot(spec, powerDbg)
    if type(spec) ~= "table" then return 0 end
    local ph = tonumber(spec.matchPw) or tonumber(spec.powerHp)
    if ph and ph > 0 then return ph end
    if type(spec.model) == "string" and type(spec.config) == "string" then
        local pw = getMatchPwForPoolEntry({}, spec.model, spec.config)
        if type(pw) == "number" and pw > 0 then return pw end
    end
    return 0
end

local function stagingDebugConfigLabelForPlanSlot(spec)
    if type(spec) ~= "table" then return "—" end
    if type(spec.model) == "string" and type(spec.config) == "string" then
        return spec.model .. "/" .. spec.config
    end
    return "—"
end

local function buildStagingSpawnDebugLinesFromPlan(powerDbg, plan)
    local lines = { stagingDebugLivePlayerLine(powerDbg) }
    for i = 1, STAGING_DEBUG_AI_SLOTS do
        local spec = plan and plan[i]
        if spec then
            local label = stagingDebugConfigLabelForPlanSlot(spec)
            local h = stagingDebugHpForPlanSlot(spec, powerDbg)
            lines[#lines + 1] = string.format("AI %d = %s, %.4f hp/kg", i, label, h)
        else
            lines[#lines + 1] = string.format("AI %d = —", i)
        end
    end
    return lines
end

local function buildStagingSpawnDebugLinesFromRecentSpawned(powerDbg, spawnedCount)
    local lines = { stagingDebugLivePlayerLine(powerDbg) }
    local total = type(mSpawnedAiVehicleIds) == "table" and #mSpawnedAiVehicleIds or 0
    local n = math.max(0, tonumber(spawnedCount) or 0)
    local startIdx = (n > 0) and (total - n + 1) or (total + 1)
    for i = 1, STAGING_DEBUG_AI_SLOTS do
        local vehIdx = startIdx + i - 1
        local vehId = mSpawnedAiVehicleIds[vehIdx]
        if vehId and core_vehicles and core_vehicles.getVehicleDetails then
            local details = core_vehicles.getVehicleDetails(vehId)
            local model = details and details.current and details.current.key
            local ckey = details and details.current and details.current.config_key
            local hp = 0
            if type(model) == "string" and type(ckey) == "string" then
                hp = tonumber(getMatchPwForPoolEntry({}, model, ckey)) or 0
            end
            lines[#lines + 1] = string.format("AI %d = %s/%s, %.4f hp/kg", i, tostring(model or "?"), tostring(ckey or "?"), hp)
        else
            lines[#lines + 1] = string.format("AI %d = —", i)
        end
    end
    return lines
end

-- Filter raw pool to rows with hp/kg <= playerPw * (1 + capPct). Legacy HP filter removed.
local function filterPoolByPowerWeight(rawPool, playerPw, cfg)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    local usePw = cfg.filterPoolByPowerWeightMeetOrExceed == true
        or cfg.filterPoolByPowerMeetOrExceed == true
    if usePw ~= true or type(playerPw) ~= "number" or playerPw < 0 then return rawPool end
    local capPct = tonumber(cfg.aiPowerExceedCapPct)
    if not capPct or capPct < 0 then capPct = tonumber(DEFAULT_CONFIG.aiPowerExceedCapPct) or 0.25 end
    local maxPw = playerPw * (1 + capPct)
    local out = {}
    for _, entry in ipairs(rawPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or entry
        if type(model) ~= "string" then goto continue end
        local configKey = type(entry) == "table" and entry.config or nil
        local poolPw = nil
        if type(entry) == "table" then
            poolPw = getMatchPwForPoolEntry(entry, model, configKey)
        else
            local data = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(model)
            local ck = configKey
            if not ck and data and data.model then
                ck = data.model.default_pc
                if not ck and data.model.configs then
                    for k, _ in pairs(data.model.configs) do ck = k break end
                end
            end
            if ck then
                poolPw = getMatchPwForPoolEntry({}, model, ck)
            end
        end
        if poolPw and poolPw <= maxPw then
            table.insert(out, entry)
        end
        ::continue::
    end
    return out
end

-- When bracket floor is set (sanctioned classPwMin), drop pool rows below that hp/kg. Uses getMatchPwForPoolEntry.
local function filterPoolByBracketMin(rawPool, minHp)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    if type(minHp) ~= "number" or minHp <= 0 then return rawPool end
    local out = {}
    for _, entry in ipairs(rawPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or entry
        if type(model) ~= "string" then goto continue end
        local configKey = type(entry) == "table" and entry.config or nil
        local poolHp = getPowerHpForPoolEntry(entry, model, configKey)
        if not poolHp or poolHp >= minHp then
            table.insert(out, entry)
        end
        ::continue::
    end
    if #out == 0 then return rawPool end
    return out
end

-- Drop pool entries above maxHp (sanctioned class ceiling). If none remain, returns rawPool unchanged unless strict.
-- strict: when true, return the filtered list even if empty (never relax back to over-max entries).
-- Uses getMatchPwForPoolEntry (catalog / legacy peakHp / filename tier).
local function filterPoolByBracketMax(rawPool, maxHp, strict)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    if type(maxHp) ~= "number" or maxHp <= 0 then return rawPool end
    local out = {}
    for _, entry in ipairs(rawPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or entry
        if type(model) ~= "string" then goto continue end
        local configKey = type(entry) == "table" and entry.config or nil
        local poolHp = getPowerHpForPoolEntry(entry, model, configKey)
        if not poolHp or poolHp <= maxHp then
            table.insert(out, entry)
        end
        ::continue::
    end
    if #out == 0 and not strict then return rawPool end
    return out
end

local function getAvailableModelLookup()
    local out = {}
    if not core_vehicles or not core_vehicles.getVehicleList then return out end
    local list = core_vehicles.getVehicleList()
    local vehicles = list and list.vehicles or {}
    for _, v in ipairs(vehicles) do
        local key = v and v.model and v.model.key
        if type(key) == "string" and key ~= "" then
            out[key] = true
        end
    end
    return out
end

-- Filter to only models that exist in the game; no fallback to "all vehicles" so we stick to aiRacers.json list (no trailers/trucks).
local function filterPoolToAvailableModels(rawPool)
    local available = getAvailableModelLookup()
    local filtered = {}
    local seen = {}
    if type(rawPool) == "table" then
        for _, entry in ipairs(rawPool) do
            local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or entry
            if type(model) == "string" and available[model] and not seen[model] then
                seen[model] = true
                table.insert(filtered, model)
            end
        end
    end
    return filtered
end

-- Filter vehiclePool (array of { model, config }) to entries whose model exists. Returns new array.
local function filterVehiclePoolToAvailable(rawPool)
    local available = getAvailableModelLookup()
    local out = {}
    if type(rawPool) ~= "table" then return out end
    for _, entry in ipairs(rawPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and available[model] and type(config) == "string" and config ~= "" then
            local row = { model = model, config = config }
            if type(entry) == "table" then
                local pk = tonumber(entry.peakHp) or tonumber(entry.hp) or tonumber(entry.powerHp)
                if pk and pk > 0 then
                    row.peakHp = pk
                end
            end
            table.insert(out, row)
        end
    end
    return out
end

-- Order of cfg.vehiclePool tiers when merging upward for AI power matching (soft class ceiling).
local VEHICLE_POOL_CLASS_ORDER = { "stock", "modified", "super", "open" }

local function vehiclePoolClassOrderIndex(class)
    if type(class) ~= "string" then return 1 end
    for i, c in ipairs(VEHICLE_POOL_CLASS_ORDER) do
        if c == class then return i end
    end
    return 1
end

-- Concatenate vehiclePool entries from startClass through open, deduped by model+config.
local function mergeVehiclePoolFromClassUpward(vehiclePool, startClass)
    local out = {}
    if type(vehiclePool) ~= "table" then return out end
    local seen = {}
    local from = vehiclePoolClassOrderIndex(startClass)
    for i = from, #VEHICLE_POOL_CLASS_ORDER do
        local tier = VEHICLE_POOL_CLASS_ORDER[i]
        local tierPool = vehiclePool[tier]
        if type(tierPool) == "table" then
            for _, entry in ipairs(tierPool) do
                local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
                local config = type(entry) == "table" and entry.config or nil
                if type(model) == "string" and type(config) == "string" and config ~= "" then
                    local key = model .. "\0" .. config
                    if not seen[key] then
                        seen[key] = true
                        table.insert(out, entry)
                    end
                end
            end
        end
    end
    return out
end

-- Merge vehiclePool tiers from the first non-empty tier (stock → open) through open. Used when a race omits e.g. stock but defines modified+.
local function mergeVehiclePoolFromFirstAvailableTier(vehiclePool)
    if type(vehiclePool) ~= "table" then return {} end
    for _, tier in ipairs(VEHICLE_POOL_CLASS_ORDER) do
        local tierPool = vehiclePool[tier]
        if type(tierPool) == "table" and #tierPool > 0 then
            return mergeVehiclePoolFromClassUpward(vehiclePool, tier)
        end
    end
    return {}
end

local function shuffleInPlace(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

local function planKeyFromRow(r)
    return (r.model or "") .. "\0" .. (r.config or "")
end

-- From a shuffled pool, pick requestedCount rows preferring unique models first, then fill (duplicate configs only as last resort).
local function pickNearestRandomVarietyPlan(pool, requestedCount)
    if type(pool) ~= "table" or #pool == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then
        return {}
    end
    local copy = {}
    for _, r in ipairs(pool) do
        table.insert(copy, r)
    end
    shuffleInPlace(copy)
    local picked = {}
    local pickedKeys = {}
    local modelUsed = {}
    for _, r in ipairs(copy) do
        if #picked >= requestedCount then
            break
        end
        local m = r.model or ""
        if not modelUsed[m] then
            modelUsed[m] = true
            local k = planKeyFromRow(r)
            if not pickedKeys[k] then
                pickedKeys[k] = true
                table.insert(picked, r)
            end
        end
    end
    for _, r in ipairs(copy) do
        if #picked >= requestedCount then
            break
        end
        local k = planKeyFromRow(r)
        if not pickedKeys[k] then
            pickedKeys[k] = true
            table.insert(picked, r)
        end
    end
    local fillIdx = 1
    while #picked < requestedCount and #copy > 0 do
        local r = copy[((fillIdx - 1) % #copy) + 1]
        fillIdx = fillIdx + 1
        table.insert(picked, { model = r.model, config = r.config, pw = r.pw })
    end
    local out = {}
    for _, r in ipairs(picked) do
        table.insert(out, { model = r.model, config = r.config, matchPw = r.pw })
    end
    return out
end

--- Pick AI lineup by smallest |matchPw - playerPw| (matchPw = catalog hp/kg, else legacy peakHp, else filename tier/1000). Random + model variety within the nearest distance band.
local function buildNearestRandomVarietyPlan(available, playerPw, requestedCount, cfg, bracketMaxPw)
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
        return {}
    end
    local ph = type(playerPw) == "number" and playerPw or 0
    if ph < 0 then
        ph = 0
    end
    local rows = {}
    for _, entry in ipairs(available) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" and config ~= "" then
            local pw = getMatchPwForPoolEntry(entry, model, config)
            if type(pw) == "number" and pw > 0 then
                local skip = type(bracketMaxPw) == "number" and bracketMaxPw > 0 and pw > bracketMaxPw + 1e-9
                if not skip then
                    table.insert(rows, {
                        model = model,
                        config = config,
                        pw = pw,
                        dist = math.abs(pw - ph),
                    })
                end
            end
        end
    end
    if #rows == 0 then
        return {}
    end
    table.sort(rows, function(a, b)
        if a.dist ~= b.dist then
            return a.dist < b.dist
        end
        if (a.model or "") ~= (b.model or "") then
            return (a.model or "") < (b.model or "")
        end
        return (a.config or "") < (b.config or "")
    end)
    local kMax = math.min(#rows, math.max(requestedCount * 4, requestedCount + 4))
    local cut = rows[kMax].dist + 1e-8
    local pool = {}
    for _, r in ipairs(rows) do
        if r.dist <= cut then
            table.insert(pool, r)
        end
    end
    shuffleInPlace(pool)
    return pickNearestRandomVarietyPlan(pool, requestedCount)
end

-- buildCloseAbovePlan: slot list of { model, config, matchPw }. hp/kg in (playerPw, playerPw+closeAbove]; else cycle full pool rows.
-- pwLow edges slightly below playerPw so same-bin catalog rows still qualify (mirrors old HP integer floor).
-- bracketMaxPw: optional sanctioned class ceiling (hp/kg).
local function buildCloseAbovePlan(available, playerPw, requestedCount, closeAbovePw, bracketMaxPw)
    local plan = {}
    local dbg = {
        branch = "none",
        availableCount = type(available) == "table" and #available or 0,
        playerHpUsed = 0,
        closeAboveCap = tonumber(closeAbovePw) or 0.0617,
        bandWindow = "",
        bandUniqueCount = 0,
        bandList = {},
        resolvedRowCount = 0,
        resolvedSample = {},
        nextCar = nil,
    }
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
        dbg.branch = "invalid_args"
        return plan, dbg
    end
    local ph = type(playerPw) == "number" and playerPw or 0
    if ph < 0 then ph = 0 end
    dbg.playerHpUsed = ph
    local pwLow = ph - math.max(1e-9, ph * 1e-7 + 1e-12)
    local cap = tonumber(closeAbovePw)
    if not cap or cap <= 0 then cap = tonumber(DEFAULT_CONFIG.aiPoolCloseAbovePw) or 0.0617 end
    dbg.closeAboveCap = cap
    local bmax = type(bracketMaxPw) == "number" and bracketMaxPw > 0 and bracketMaxPw or nil
    local bandHi = ph + cap
    if bmax then
        bandHi = math.min(bandHi, bmax)
    end
    dbg.bandWindow = string.format("(%.4f, %.4f]", ph, bandHi)

    local rows = {}
    for _, entry in ipairs(available) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" and config ~= "" then
            local aiPw = getMatchPwForPoolEntry(entry, model, config)
            if type(aiPw) == "number" and aiPw > 0 then
                table.insert(rows, { model = model, config = config, pw = aiPw })
            end
        end
    end
    dbg.resolvedRowCount = #rows
    for i = 1, math.min(#rows, 14) do
        local r = rows[i]
        table.insert(dbg.resolvedSample, string.format("%s/%s=%.4f", r.model, r.config, r.pw))
    end
    if #rows > 14 then
        table.insert(dbg.resolvedSample, string.format("... +%d more", #rows - 14))
    end

    local band = {}
    for _, r in ipairs(rows) do
        if r.pw > pwLow and r.pw <= bandHi then
            table.insert(band, r)
        end
    end
    table.sort(band, function(a, b)
        if a.pw ~= b.pw then return a.pw < b.pw end
        return (a.model or "") < (b.model or "")
    end)

    local seen = {}
    local unique = {}
    for _, r in ipairs(band) do
        local k = (r.model or "") .. "\0" .. (r.config or "")
        if not seen[k] then
            seen[k] = true
            table.insert(unique, r)
            table.insert(dbg.bandList, string.format("%s/%s %.4f hp/kg", r.model, r.config, r.pw))
        end
    end
    dbg.bandUniqueCount = #unique

    if #unique >= 1 then
        dbg.branch = "band_cycle"
        for i = 1, requestedCount do
            local r = unique[((i - 1) % #unique) + 1]
            table.insert(plan, { model = r.model, config = r.config, matchPw = r.pw })
        end
        return plan, dbg
    end

    local above = {}
    for _, r in ipairs(rows) do
        if r.pw > pwLow and (not bmax or r.pw <= bmax) then
            table.insert(above, r)
        end
    end
    if #above == 0 then
        if #rows > 0 then
            dbg.branch = "all_cycle_rows_no_band"
            fillSpawnPlanCyclingRows(plan, rows, requestedCount)
        else
            dbg.branch = "empty_no_rows"
        end
        return plan, dbg
    end
    table.sort(above, function(a, b)
        if a.pw ~= b.pw then return a.pw < b.pw end
        return (a.model or "") < (b.model or "")
    end)
    local pick = above[1]
    dbg.branch = "fallback_one_pool_rest_cycle"
    dbg.nextCar = string.format("%s/%s %.4f hp/kg", pick.model, pick.config, pick.pw)
    table.insert(plan, { model = pick.model, config = pick.config, matchPw = pick.pw })
    fillSpawnPlanCyclingRows(plan, rows, requestedCount)
    return plan, dbg
end

-- Racing team business sanctioned: same windows as buildCloseAbovePlan but hp/kg; max 2 per pool identity.
local function buildBusinessSanctionedPlan(available, playerPw, requestedCount, closeAbovePw, bracketMaxPw)
    local plan = {}
    local dbg = {
        branch = "business_sanctioned",
        availableCount = type(available) == "table" and #available or 0,
        playerHpUsed = 0,
        closeAboveCap = tonumber(closeAbovePw) or 0.0617,
        aboveWindow = "",
        belowWindow = "",
        aboveAdded = 0,
        belowAdded = 0,
        cyclesAdded = 0,
        resolvedRowCount = 0,
        resolvedSample = {},
    }
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
        dbg.branch = "invalid_args"
        return plan, dbg
    end
    local ph = type(playerPw) == "number" and playerPw or 0
    if ph < 0 then ph = 0 end
    dbg.playerHpUsed = ph
    local pwLow = ph - math.max(1e-9, ph * 1e-7 + 1e-12)
    local cap = tonumber(closeAbovePw)
    if not cap or cap <= 0 then cap = tonumber(DEFAULT_CONFIG.aiPoolCloseAbovePw) or 0.0617 end
    dbg.closeAboveCap = cap
    local bmax = type(bracketMaxPw) == "number" and bracketMaxPw > 0 and bracketMaxPw or nil
    local bandHi = ph + cap
    if bmax then
        bandHi = math.min(bandHi, bmax)
    end
    local bandLo = ph - cap
    dbg.aboveWindow = string.format("(%.4f, %.4f]", ph, bandHi)
    dbg.belowWindow = string.format("[%.4f, %.4f)", bandLo, ph)

    local rows = {}
    for _, entry in ipairs(available) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" and config ~= "" then
            local aiPw = getMatchPwForPoolEntry(entry, model, config)
            if type(aiPw) == "number" and aiPw > 0 then
                table.insert(rows, { model = model, config = config, pw = aiPw })
            end
        end
    end
    dbg.resolvedRowCount = #rows
    for i = 1, math.min(#rows, 14) do
        local r = rows[i]
        table.insert(dbg.resolvedSample, string.format("%s/%s=%.4f", r.model, r.config, r.pw))
    end
    if #rows > 14 then
        table.insert(dbg.resolvedSample, string.format("... +%d more", #rows - 14))
    end

    local above = {}
    local below = {}
    for _, r in ipairs(rows) do
        if r.pw > pwLow and r.pw <= bandHi then
            table.insert(above, r)
        elseif r.pw >= bandLo and r.pw < ph then
            if not bmax or r.pw <= bmax then
                table.insert(below, r)
            end
        end
    end
    table.sort(above, function(a, b)
        if a.pw ~= b.pw then return a.pw < b.pw end
        return (a.model or "") < (b.model or "")
    end)
    table.sort(below, function(a, b)
        if a.pw ~= b.pw then return a.pw < b.pw end
        return (a.model or "") < (b.model or "")
    end)

    local maxPerIdentity = 2
    local counts = {}

    local function poolKey(r)
        return (r.model or "") .. "\0" .. (r.config or "")
    end

    local function fillFromBand(band)
        if type(band) ~= "table" or #band == 0 then return end
        local rep = {}
        for _, r in ipairs(band) do
            local k = poolKey(r)
            local ex = rep[k]
            if not ex or r.pw < ex.pw then
                rep[k] = r
            end
        end
        local order = {}
        for _, r in pairs(rep) do
            table.insert(order, r)
        end
        table.sort(order, function(a, b)
            if a.pw ~= b.pw then return a.pw < b.pw end
            return poolKey(a) < poolKey(b)
        end)
        while #plan < requestedCount do
            local added = false
            for _, r in ipairs(order) do
                if #plan >= requestedCount then break end
                local k = poolKey(r)
                if (counts[k] or 0) < maxPerIdentity then
                    table.insert(plan, { model = r.model, config = r.config, matchPw = r.pw })
                    counts[k] = (counts[k] or 0) + 1
                    added = true
                end
            end
            if not added then break end
        end
    end

    local n0 = #plan
    fillFromBand(above)
    dbg.aboveAdded = #plan - n0
    n0 = #plan
    fillFromBand(below)
    dbg.belowAdded = #plan - n0
    while #plan < requestedCount do
        if #rows > 0 then
            local r = rows[((#plan) % #rows) + 1]
            table.insert(plan, { model = r.model, config = r.config, matchPw = r.pw })
            dbg.cyclesAdded = dbg.cyclesAdded + 1
        else
            break
        end
    end
    if dbg.aboveAdded > 0 and dbg.belowAdded > 0 then
        dbg.branch = dbg.cyclesAdded > 0 and "business_above_below_cycle" or "business_above_below_only"
    elseif dbg.aboveAdded > 0 then
        dbg.branch = dbg.cyclesAdded > 0 and "business_above_cycle" or "business_above_only"
    elseif dbg.belowAdded > 0 then
        dbg.branch = dbg.cyclesAdded > 0 and "business_below_cycle" or "business_below_only"
    else
        dbg.branch = dbg.cyclesAdded > 0 and "business_all_cycle" or "business_empty"
    end
    return plan, dbg
end

-- Racing team proxy: pool configs with hp/kg in [pwMin, pwMax], preferring highest pw in band.
local function buildBracketMaxBiasedPlan(available, pwMin, pwMax, requestedCount)
    local plan = {}
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
        return plan
    end
    local hmin = tonumber(pwMin) or 0
    local hmax = tonumber(pwMax) or 0
    if hmax < hmin then hmax = hmin end
    local rows = {}
    for _, entry in ipairs(available) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" and config ~= "" then
            local aiPw = getMatchPwForPoolEntry(entry, model, config)
            if type(aiPw) == "number" and aiPw > 0 and aiPw >= hmin and aiPw <= hmax then
                table.insert(rows, { model = model, config = config, pw = aiPw })
            end
        end
    end
    if #rows == 0 then
        return plan
    end
    table.sort(rows, function(a, b)
        if a.pw ~= b.pw then return a.pw > b.pw end
        if (a.model or "") ~= (b.model or "") then return (a.model or "") < (b.model or "") end
        return (a.config or "") < (b.config or "")
    end)
    local maxPerIdentity = 2
    local counts = {}
    local function poolKey(r)
        return (r.model or "") .. "\0" .. (r.config or "")
    end
    while #plan < requestedCount do
        local added = false
        for _, r in ipairs(rows) do
            if #plan >= requestedCount then break end
            local k = poolKey(r)
            if (counts[k] or 0) < maxPerIdentity then
                table.insert(plan, { model = r.model, config = r.config, matchPw = r.pw })
                counts[k] = (counts[k] or 0) + 1
                added = true
            end
        end
        if not added then
            local n = #rows
            while #plan < requestedCount and n > 0 do
                local r = rows[((#plan) % n) + 1]
                table.insert(plan, { model = r.model, config = r.config, matchPw = r.pw })
            end
            break
        end
    end
    return plan
end

local function buildStrictClassFallbackPlanFromVehiclePool(cfg, classId, requestedCount, minPw, maxPw)
    if type(cfg) ~= "table" or type(cfg.vehiclePool) ~= "table" then return {} end
    if type(requestedCount) ~= "number" or requestedCount < 1 then return {} end
    local tier = cfg.vehiclePool[classId]
    if type(tier) ~= "table" or #tier == 0 then return {} end
    local available = filterVehiclePoolToAvailable(tier)
    available = filterPoolByBracketMin(available, minPw)
    available = filterPoolByBracketMax(available, maxPw, true)
    if type(available) ~= "table" or #available == 0 then
        return {}
    end
    local rows = {}
    for _, entry in ipairs(available) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and model ~= "" and type(config) == "string" and config ~= "" then
            local pw = getMatchPwForPoolEntry(entry, model, config)
            table.insert(rows, {
                model = model,
                config = config,
                matchPw = pw,
            })
        end
    end
    if #rows == 0 then return {} end
    local out = {}
    for i = 1, requestedCount do
        local r = rows[((i - 1) % #rows) + 1]
        out[i] = { model = r.model, config = r.config, matchPw = r.matchPw }
    end
    return out
end

-- Execute a staging plan: pool rows { model, config, matchPw? }. Config path uses merged race subdir when basename-only.
local function spawnStagingPlan(raceName, race, facilityName, slotPlan)
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    if type(slotPlan) ~= "table" or #slotPlan == 0 then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local n = math.max(0, math.min(#spots, requestedCount, #slotPlan))
    if n <= 0 then return 0 end
    local pathCfg = race and getMergedConfigForRace(race) or cfg

    local spawned = 0
    local spawnedLineup = {}
    for i = 1, n do
        local spec = slotPlan[i]
        local spot = spots[i]
        if spec and spot and spot.pos and spot.rot then
            local modelKey, configForSpawn
            if type(spec.model) == "string" and spec.model ~= "" and type(spec.config) == "string" and spec.config ~= "" then
                modelKey = spec.model
                local rel = poolConfigRelPathForSpawn(spec, modelKey, spec.config, pathCfg)
                if rel then
                    configForSpawn = "vehicles/" .. modelKey .. "/" .. rel .. ".pc"
                end
            end
            if modelKey and configForSpawn then
                local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
                local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
                local spawnOptions = { pos = pos, rot = rot, config = configForSpawn, autoEnterVehicle = false }
                local ok, veh = pcall(function() return core_vehicles.spawnNewVehicle(modelKey, spawnOptions) end)
                if ok and veh and veh.getID then
                    local vehId = veh:getID()
                    table.insert(mSpawnedAiVehicleIds, vehId); mEverSpawnedAiVehicleIdsSweep[vehId] = true
                    spawned = spawned + 1
                    table.insert(spawnedLineup, {
                        model = modelKey,
                        config = spec.config or "default",
                        matchPw = tonumber(spec.matchPw) or tonumber(spec.powerHp) or nil,
                    })
                    pcall(function()
                        applyAiBasePaintOnly(vehId, pickRandomAiColor())
                    end)
                    local vehObj = be:getObjectByID(vehId)
                    if vehObj then
                        vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                        vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                        vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                        vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                        if cfg.startEngineOnSpawn ~= false then
                            queueEngineStart(vehObj)
                        end
                    end
                end
            end
        end
    end
    setLastSpawnedLineupSnapshot(spawnedLineup)
    return spawned
end

local function buildCircularPlanFromPoolRows(avail, requestedCount)
    local plan = {}
    if type(avail) ~= "table" or #avail == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then
        return plan
    end
    for i = 1, requestedCount do
        local r = avail[((i - 1) % #avail) + 1]
        local model = type(r) == "table" and (r.model or r.vehicleModel) or nil
        local config = type(r) == "table" and r.config or nil
        if type(model) == "string" and type(config) == "string" and config ~= "" then
            plan[#plan + 1] = {
                model = model,
                config = config,
                matchPw = getMatchPwForPoolEntry(r, model, config),
            }
        end
    end
    return plan
end

-- Last-resort: spawn from first non-empty vehiclePool tier (subdir-prefixed when merged). Returns spawned count.
local function spawnFromStructuredPoolLastResort(raceName, race, facilityName, cfg, requestedCount)
    if type(cfg) ~= "table" or type(cfg.vehiclePool) ~= "table" then
        return 0
    end
    local merged = mergeVehiclePoolFromFirstAvailableTier(cfg.vehiclePool)
    local avail = filterVehiclePoolToAvailable(merged)
    if #avail == 0 then
        return 0
    end
    local plan = buildCircularPlanFromPoolRows(avail, requestedCount)
    if #plan == 0 then
        return 0
    end
    return spawnStagingPlan(raceName, race, facilityName, plan)
end

-- Pick N entries from class pool: sort by closest power to playerHp, then one per model first, then fill. Random among ties. Returns list of { model, config }.
local function pickVehiclePoolByClosestWithVariety(classPool, playerPowerHp, requestedCount)
    if type(classPool) ~= "table" or #classPool == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then return {} end
    local withPower = {}
    for _, entry in ipairs(classPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" then
            local hp = getPowerForModelConfig(model, config)
            if type(hp) == "number" and hp > 0 then
                table.insert(withPower, { model = model, config = config, powerHp = hp })
            else
                table.insert(withPower, { model = model, config = config, powerHp = playerPowerHp or 200 })
            end
        end
    end
    if #withPower == 0 then return {} end
    local ph = type(playerPowerHp) == "number" and playerPowerHp or 200
    for i = #withPower, 2, -1 do
        local j = math.random(1, i)
        withPower[i], withPower[j] = withPower[j], withPower[i]
    end
    table.sort(withPower, function(a, b)
        local ahp = a.powerHp or ph
        local bhp = b.powerHp or ph
        local da = math.abs(ahp - ph)
        local db = math.abs(bhp - ph)
        local aClose = da <= CLOSE_HP_TOLERANCE
        local bClose = db <= CLOSE_HP_TOLERANCE
        if aClose and not bClose then return true end
        if not aClose and bClose then return false end
        if aClose and bClose then return da < db end
        -- After "within 25 HP": prefer next closest but always higher (power >= player), then below player by closest
        local aAbove = ahp >= ph
        local bAbove = bhp >= ph
        if aAbove and not bAbove then return true end
        if not aAbove and bAbove then return false end
        if aAbove and bAbove then return (ahp - ph) < (bhp - ph) end
        return da < db
    end)
    local picked = {}
    local usedModel = {}
    for _, e in ipairs(withPower) do
        if not usedModel[e.model] then
            usedModel[e.model] = true
            table.insert(picked, { model = e.model, config = e.config })
            if #picked >= requestedCount then return picked end
        end
    end
    for _, e in ipairs(withPower) do
        if #picked >= requestedCount then break end
        local already = 0
        for _, p in ipairs(picked) do if p.model == e.model then already = already + 1 end end
        if already < 2 then
            table.insert(picked, { model = e.model, config = e.config })
        end
    end
    while #picked < requestedCount and #withPower > 0 do
        table.insert(picked, { model = withPower[1].model, config = withPower[1].config })
    end
    return picked
end

local function pickRandomVehicleModel(pool)
    if type(pool) ~= "table" or #pool == 0 then return DEFAULT_CONFIG.defaultVehiclePool[1] end
    local pick = pool[math.random(1, #pool)]
    if type(pick) == "table" then
        return pick.model or pick.vehicleModel or DEFAULT_CONFIG.defaultVehiclePool[1]
    end
    return pick
end

-- Internal: spawn AI using model-only pool keys; config path uses aiRaceConfigSubdir (merged cfg) or rls_race_ai/default.pc.
local function spawnWithPool(raceName, race, facilityName, rawPool, spawnCfg)
    local cfg = (type(spawnCfg) == "table" and spawnCfg) or getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount))
    if spawnCount <= 0 then return 0 end
    local pool = filterPoolToAvailableModels(rawPool or cfg.defaultVehiclePool)
    local subdir = aiRaceConfigSubdirForFallbackSpawn(cfg)
    local spawned = 0
    local spawnedLineup = {}
    local maxRetries = 3
    for i = 1, spawnCount do
        local spot = spots[i]
        if spot and spot.pos and spot.rot then
            local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
            local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
            local veh = nil
            local chosenModel = nil
            local chosenRel = nil
            local candidates = {}
            local seen = {}
            for _ = 1, maxRetries do
                local model = pickRandomVehicleModel(pool)
                if model and not seen[model] then
                    seen[model] = true
                    candidates[#candidates + 1] = model
                end
            end
            for _, model in ipairs(candidates) do
                local rel = (subdir ~= "" and (subdir .. "/default")) or "default"
                local configPath = "vehicles/" .. model .. "/" .. rel .. ".pc"
                local spawnOptions = { pos = pos, rot = rot, config = configPath, autoEnterVehicle = false }
                local ok, result = pcall(function() return core_vehicles.spawnNewVehicle(model, spawnOptions) end)
                if ok and result and result.getID then
                    veh = result
                    chosenModel = model
                    chosenRel = rel
                    break
                end
            end
            if veh then
                local vehId = veh:getID()
                table.insert(mSpawnedAiVehicleIds, vehId); mEverSpawnedAiVehicleIdsSweep[vehId] = true
                spawned = spawned + 1
                table.insert(spawnedLineup, { model = chosenModel or candidates[1] or "unknown", config = chosenRel or "default" })
                pcall(function()
                    applyAiBasePaintOnly(vehId, pickRandomAiColor())
                end)
                local vehObj = be:getObjectByID(vehId)
                if vehObj then
                    vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                    if cfg.startEngineOnSpawn ~= false then
                        queueEngineStart(vehObj)
                    end
                end
            end
        end
    end
    setLastSpawnedLineupSnapshot(spawnedLineup)
    return spawned
end

-- Internal: spawn AI at staging spots using a pre-ordered list of { model, config }. One entry per spot. Returns spawned count.
local function spawnWithModelConfigList(raceName, race, facilityName, list)
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    if type(list) ~= "table" or #list == 0 then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount, #list))
    if spawnCount <= 0 then return 0 end
    local pathCfg = race and getMergedConfigForRace(race) or cfg
    local spawned = 0
    local spawnedLineup = {}
    for i = 1, spawnCount do
        local spot = spots[i]
        local entry = list[i]
        if spot and spot.pos and spot.rot and entry and entry.model and entry.config then
            local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
            local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
            local rel = poolConfigRelPathForSpawn(entry, entry.model, entry.config, pathCfg) or entry.config
            local configPath = "vehicles/" .. entry.model .. "/" .. rel .. ".pc"
            local spawnOptions = { pos = pos, rot = rot, config = configPath, autoEnterVehicle = false }
            local ok, veh = pcall(function() return core_vehicles.spawnNewVehicle(entry.model, spawnOptions) end)
            if ok and veh and veh.getID then
                local vehId = veh:getID()
                table.insert(mSpawnedAiVehicleIds, vehId); mEverSpawnedAiVehicleIdsSweep[vehId] = true
                spawned = spawned + 1
                table.insert(spawnedLineup, {
                    model = tostring(entry.model),
                    config = tostring(rel),
                    matchPw = tonumber(entry.matchPw) or tonumber(entry.powerHp) or nil,
                })
                pcall(function()
                    applyAiBasePaintOnly(vehId, pickRandomAiColor())
                end)
                local vehObj = be:getObjectByID(vehId)
                if vehObj then
                    vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                    if cfg.startEngineOnSpawn ~= false then
                        queueEngineStart(vehObj)
                    end
                end
            end
        end
    end
    setLastSpawnedLineupSnapshot(spawnedLineup)
    return spawned
end

-- Spawn AI vehicles at AI staging spots for this facility/race. They remain stopped until releaseAndDrive().
function M.spawnForStaging(raceName, race, facilityName)
    local cfg = race and getMergedConfigForRace(race) or getCurrentLevelConfig()
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    if type(cfg.vehiclePool) == "table" then
        local n = spawnFromStructuredPoolLastResort(raceName, race, facilityName, cfg, requestedCount)
        if n > 0 then
            return n
        end
    end
    local rawPool = getVehiclePoolForRace(raceName, race, facilityName, cfg)
    return spawnWithPool(raceName, race, facilityName, rawPool, cfg)
end

-- Spawn AI matched on hp/kg (peakPw pools). poolReferenceHp / poolReferenceHpMin carry hp/kg (legacy param names).
-- sanctionedSpawnCtx.classPwMin/classPwMax (or legacy classHp*) bracket filters and fallbacks.
-- Player hp/kg: same resolver as staging UI (trusted live cache, else sync catalog), then optional async live refresh.
local MAX_POOL_REFERENCE_PW = 3.6 -- ignore mistaken crank-HP values passed where hp/kg is expected (~0.05–1.2 typical; modded higher)

function M.spawnForStagingWithPlayerHp(raceName, race, facilityName, callback, poolReferenceHp, poolReferenceHpMin, sanctionedSpawnCtx)
    if type(callback) ~= "function" then return end
    local cfg = race and getMergedConfigForRace(race) or getCurrentLevelConfig()
    if cfg.enabled == false then
        callback(0)
        return
    end
    local function resolveCloseAbovePw()
        local cap = tonumber(cfg.aiPoolCloseAbovePw)
        if cap and cap > 0 then
            return cap
        end
        local leg = tonumber(cfg.aiPoolCloseAboveHp)
        if leg and leg > 10 then
            -- Legacy aiPoolCloseAboveHp (HP): old hp/lb heuristic was leg/2700; ×2.2046226218 → same window in hp/kg.
            return (leg / 2700) * 2.2046226218
        end
        return tonumber(DEFAULT_CONFIG.aiPoolCloseAbovePw) or 0.0617
    end

    local function spawnFromPlayerPw(playerPw, powerDbg)
        powerDbg = type(powerDbg) == "table" and powerDbg or {}
        local hp = type(playerPw) == "number" and playerPw or 0
        local hpMin = type(poolReferenceHpMin) == "number" and poolReferenceHpMin > 0 and poolReferenceHpMin or nil
        if hpMin and hpMin > MAX_POOL_REFERENCE_PW then
            hpMin = nil
        end
        local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 4
        local closeAbove = resolveCloseAbovePw()
        local businessSanctionedOffer = type(sanctionedSpawnCtx) == "table" and sanctionedSpawnCtx.racingTeamBusinessOffer == true

        local bracketOnly = type(sanctionedSpawnCtx) == "table" and sanctionedSpawnCtx.racingTeamProxyBracketOnlyAi == true
        local bmin = bracketOnly
            and (tonumber(sanctionedSpawnCtx.classPwMin) or tonumber(sanctionedSpawnCtx.classHpMin))
            or nil
        local bmax = bracketOnly
            and (tonumber(sanctionedSpawnCtx.classPwMax) or tonumber(sanctionedSpawnCtx.classHpMax))
            or nil
        if bracketOnly and bmin and bmax and bmax > 0 and bmin > 0 and bmax >= bmin then
            local skillT = 1
            if type(sanctionedSpawnCtx) == "table" and sanctionedSpawnCtx.racingTeamProxyAiDifficultyT ~= nil then
                skillT = tonumber(sanctionedSpawnCtx.racingTeamProxyAiDifficultyT) or 1
            end
            skillT = math.max(0, math.min(1, skillT))
            local span = bmax - bmin
            local effectiveBmax = bmax
            if span > 0 then
                -- Invert power handicap: higher driver skill reduces opponent max power (giving the driver an advantage)
                local oppScale = 1 - skillT
                if hp > 0 then
                    local softCap = math.max(bmin, math.min(bmax, hp - PROXY_BRACKET_SOFT_PW_BELOW_PLAYER))
                    effectiveBmax = softCap + (bmax - softCap) * oppScale
                else
                    local frac = 0.75 + 0.25 * oppScale
                    effectiveBmax = bmin + span * frac
                end
                effectiveBmax = math.max(bmin, math.min(bmax, effectiveBmax))
            end
            if type(cfg.vehiclePool) == "table" then
                local merged = mergeVehiclePoolFromFirstAvailableTier(cfg.vehiclePool)
                local availableBase = filterVehiclePoolToAvailable(merged)
                local available = filterPoolByBracketMin(availableBase, bmin)
                available = filterPoolByBracketMax(available, effectiveBmax)
                if #available > 0 then
                    local plan = buildBracketMaxBiasedPlan(available, bmin, effectiveBmax, requestedCount)
                    if #plan > 0 then
                        local spawned = spawnStagingPlan(raceName, race, facilityName, plan)
                        if aiSpawnDebugEnabled(cfg) then
                            showAiSpawnDebugUi(cfg, buildStagingSpawnDebugLinesFromPlan(powerDbg, plan))
                        end
                        callback(spawned)
                        return
                    end
                end
            end
            if aiSpawnDebugEnabled(cfg) then
                showAiSpawnDebugUi(cfg, {
                    "racing team proxy: bracket pool empty — falling through to main pool spawn",
                    string.format("effectiveBmax=%s (bracket %s–%s)", tostring(effectiveBmax), tostring(bmin), tostring(bmax)),
                })
            end
        end

        local sanctionedBracketMax = nil
        if businessSanctionedOffer and type(sanctionedSpawnCtx) == "table" then
            local sm = tonumber(sanctionedSpawnCtx.classPwMax) or tonumber(sanctionedSpawnCtx.classHpMax)
            if sm and sm > 0 then
                sanctionedBracketMax = sm
            end
        end

        if type(cfg.vehiclePool) == "table" and type(cfg.vehiclePool.stock) == "table" then
            local effHp = hp
            if effHp <= 0 and type(sanctionedSpawnCtx) == "table" then
                local hi = tonumber(sanctionedSpawnCtx.classPwMax) or tonumber(sanctionedSpawnCtx.classHpMax)
                if hi and hi > 0 then
                    effHp = hi
                end
            end
            if effHp > 0 then
                local startClass = getClassFromHpForVehiclePool(effHp)
                local merged = mergeVehiclePoolFromClassUpward(cfg.vehiclePool, startClass)
                local availableBase = filterVehiclePoolToAvailable(merged)
                local available = filterPoolByBracketMin(availableBase, hpMin)
                if #available == 0 then
                    available = availableBase
                end
                if sanctionedBracketMax then
                    available = filterPoolByBracketMax(available, sanctionedBracketMax, true)
                end
                if #available > 0 then
                    local availablePw = filterPoolByPowerWeight(available, effHp, cfg)
                    if type(availablePw) ~= "table" or #availablePw == 0 then
                        availablePw = available
                    end
                    local plan = buildNearestRandomVarietyPlan(availablePw, effHp, requestedCount, cfg, sanctionedBracketMax)
                    if #plan == 0 then
                        if businessSanctionedOffer then
                            plan = select(1, buildBusinessSanctionedPlan(available, effHp, requestedCount, closeAbove, sanctionedBracketMax))
                        else
                            plan = select(1, buildCloseAbovePlan(available, effHp, requestedCount, closeAbove, sanctionedBracketMax))
                        end
                    end
                    if businessSanctionedOffer and #plan == 0 then
                        local tierClass = getClassFromHpForVehiclePool(effHp)
                        local strictPlan = buildStrictClassFallbackPlanFromVehiclePool(
                            cfg,
                            tierClass,
                            requestedCount,
                            hpMin,
                            sanctionedBracketMax
                        )
                        if #strictPlan > 0 then
                            plan = strictPlan
                        end
                    end
                    if #plan > 0 then
                        local spawned = spawnStagingPlan(raceName, race, facilityName, plan)
                        if aiSpawnDebugEnabled(cfg) then
                            showAiSpawnDebugUi(cfg, buildStagingSpawnDebugLinesFromPlan(powerDbg, plan))
                        end
                        callback(spawned)
                        return
                    end
                end
            end
        end
        local spawned = spawnFromStructuredPoolLastResort(raceName, race, facilityName, cfg, requestedCount)
        if spawned <= 0 then
            local class = getDcbaClassFromPlayerPw(hp)
            local rawPool = getVehiclePoolForHpClass(cfg, class)
            local pool = filterPoolByPowerWeight(rawPool, hp, cfg)
            pool = filterPoolByBracketMin(pool, hpMin)
            if type(pool) ~= "table" or #pool == 0 then
                pool = filterPoolByPowerWeight(rawPool, hp, cfg)
            end
            if type(pool) ~= "table" or #pool == 0 then
                pool = rawPool
            end
            if sanctionedBracketMax then
                local capped = filterPoolByBracketMax(pool, sanctionedBracketMax, true)
                if #capped > 0 then
                    pool = capped
                else
                    local wide = filterPoolByBracketMin(rawPool, hpMin)
                    capped = filterPoolByBracketMax(wide, sanctionedBracketMax, true)
                    if #capped > 0 then
                        pool = capped
                    end
                end
            end
            spawned = spawnWithPool(raceName, race, facilityName, pool, cfg)
        end
        if aiSpawnDebugEnabled(cfg) then
            showAiSpawnDebugUi(cfg, buildStagingSpawnDebugLinesFromRecentSpawned(powerDbg, spawned))
        end
        callback(spawned)
    end

    local function resolvePlayerPwFromStagingUi()
        if type(M.getPlayerVehiclePwForStagingUi) ~= "function" then
            return nil, nil
        end
        return M.getPlayerVehiclePwForStagingUi()
    end

    local pwStaging, srcStaging = resolvePlayerPwFromStagingUi()
    if type(pwStaging) == "number" and pwStaging > 0 then
        spawnFromPlayerPw(pwStaging, {
            liveWatts = nil,
            playerPwDbg = pwStaging,
            usedPoolRefHp = false,
            usedStagingUiPw = true,
            stagingUiSource = srcStaging,
        })
        return
    end

    M.getPlayerVehiclePowerReliable(function(powerWatts, weight)
        local powerHp = (type(powerWatts) == "number" and powerWatts > 0) and powerWattsToHp(powerWatts) or nil
        local wkg = tonumber(weight)
        local playerPw = (powerHp and wkg and wkg > 0) and hpPerKgFromHpAndWeightKg(powerHp, wkg) or nil
        local powerDbg = {
            liveWatts = powerWatts,
            playerPwDbg = playerPw,
            usedPoolRefHp = false,
        }
        local ctx = sanctionedSpawnCtx
        local sanctionedActive = type(ctx) == "table"
            and ((tonumber(ctx.classPwMax) or tonumber(ctx.classHpMax) or 0) > 0)
        local hp = playerPw
        if (not hp or hp <= 0) then
            local pwUi, srcUi = resolvePlayerPwFromStagingUi()
            if type(pwUi) == "number" and pwUi > 0 then
                hp = pwUi
                powerDbg.usedStagingUiPw = true
                powerDbg.stagingUiSource = srcUi
                powerDbg.playerPwDbg = pwUi
            end
        end
        if (not hp or hp <= 0) and not sanctionedActive and type(poolReferenceHp) == "number" and poolReferenceHp > 0 then
            if poolReferenceHp <= MAX_POOL_REFERENCE_PW then
                hp = poolReferenceHp
                powerDbg.usedPoolRefHp = true
            end
        end
        spawnFromPlayerPw(hp or 0, powerDbg)
    end, { preferLive = true })
end

M.spawnForStagingWithPlayerPw = M.spawnForStagingWithPlayerHp

-- Build script path: first point = vehicle position + dir + up (so game does not move the car). Then track points from nearest, close loop.
local function buildScriptPathNoTeleport(path, vpos, vdir, vup)
    if not path or #path == 0 or not vpos then return nil end
    local cfg = getCurrentLevelConfig()
    local pathWidth = tonumber(cfg.scriptPathWidth) or DEFAULT_CONFIG.scriptPathWidth or 2.5
    local px, py, pz = vpos.x, vpos.y, vpos.z
    local bestI, bestD = 1, 1e30
    for i, node in ipairs(path) do
        local dx = (node.x or 0) - px
        local dy = (node.y or 0) - py
        local dz = (node.z or 0) - pz
        local d = dx*dx + dy*dy + dz*dz
        if d < bestD then bestD, bestI = d, i end
    end
    local function addRadius(node)
        local n = type(node) == "table" and node or { x = 0, y = 0, z = 0 }
        if n.r == nil then n.r = pathWidth end
        return n
    end
    local out = {}
    -- First points are local bootstrap points so script mode keeps heading and avoids start-line snaps.
    local first = addRadius({ x = px, y = py, z = pz })
    local dirx, diry, dirz
    if vdir and (vdir.x or vdir.y or vdir.z) then
        dirx, diry, dirz = vdir.x or 0, vdir.y or 0, vdir.z or 0
        first.dir = { x = dirx, y = diry, z = dirz }
        first.up = vup and { x = vup.x or 0, y = vup.y or 0, z = vup.z or 0 } or nil
    end
    if not dirx then
        local nextNode = path[bestI] or path[1]
        local dx = (nextNode.x or px) - px
        local dy = (nextNode.y or py) - py
        local dz = (nextNode.z or pz) - pz
        local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
        if mag > 0.001 then
            dirx, diry, dirz = dx / mag, dy / mag, dz / mag
            first.dir = { x = dirx, y = diry, z = dirz }
        end
    end
    table.insert(out, first)
    if dirx and diry and dirz then
        local bootstrap = math.max(1, tonumber(cfg.scriptBootstrapDistance) or DEFAULT_CONFIG.scriptBootstrapDistance)
        table.insert(out, addRadius({ x = px + dirx * math.min(2.5, bootstrap * 0.5), y = py + diry * math.min(2.5, bootstrap * 0.5), z = pz + dirz * math.min(2.5, bootstrap * 0.5) }))
        table.insert(out, addRadius({ x = px + dirx * bootstrap, y = py + diry * bootstrap, z = pz + dirz * bootstrap }))
    end
    for i = bestI, #path do table.insert(out, addRadius(path[i])) end
    for i = 1, bestI - 1 do table.insert(out, addRadius(path[i])) end
    table.insert(out, out[1])
    return out
end

local function clamp(n, minValue, maxValue)
    if n < minValue then return minValue end
    if n > maxValue then return maxValue end
    return n
end

local function randomAggression(cfg, race)
    local minAgg = tonumber((race and race.aggressionMin) or cfg.aggressionMin) or DEFAULT_CONFIG.aggressionMin
    local maxAgg = tonumber((race and race.aggressionMax) or cfg.aggressionMax) or DEFAULT_CONFIG.aggressionMax
    if maxAgg < minAgg then maxAgg = minAgg end
    local raw = minAgg + math.random() * (maxAgg - minAgg)
    return clamp(raw, 0.2, 1.5)
end

local function setPlayersAiParams(cfg)
    local ctf = gameplay_events_freeroam_competitiveTrackFlow
    if not ctf or not ctf.getRacingTeamProxyAiDifficultyT then return end
    
    local skillT = ctf.getRacingTeamProxyAiDifficultyT()
    if not skillT then return end

    skillT = math.max(0, math.min(1, tonumber(skillT) or 0))
    cfg.aggression = 0.88 + 0.32 * skillT
    cfg.raceTrafficPassBlend = 0.20 + 0.65 * skillT
    cfg.raceClearanceScaleMin = 0.58 - 0.28 * skillT
    cfg.raceCornerLineLiftScale = 0.70 + 0.65 * skillT
    cfg.targetSpeedSmootherRate = math.floor(16 + 12 * skillT + 0.5)
    cfg.raceThrottleRateMult = 3.0 + 3.0 * skillT
    cfg.raceUndersteerSlipMin = 1.02 + 0.14 * skillT
    cfg.raceCommitCorners = true
end

local function getRacingParameters(cfg, race)
    if not cfg or cfg.useRacingParameters == false then
        return {}
    end
    local scale = tonumber(cfg.raceAccelScale)
    if scale == nil or scale <= 0 then
        scale = 1.1
    end
    local kp = tonumber(cfg.raceThrottleKp)
    if kp == nil or kp <= 0 then
        kp = 1.12
    end
    local trm = tonumber(cfg.raceThrottleRateMult)
    if trm == nil or trm <= 0 then
        trm = 4
    end
    local trc = tonumber(cfg.raceThrottleRecoveryMult)
    if trc == nil or trc <= 0 then
        trc = 1.9
    end
    local params = {
        raceAccelScale = scale,
        raceThrottleKp = kp,
        raceThrottleRateMult = trm,
        raceThrottleRecoveryMult = trc
    }
    local rwt = tonumber(cfg.raceWideLineTrafficBlend)
    if rwt == nil then rwt = tonumber(DEFAULT_CONFIG.raceWideLineTrafficBlend) or 0.4 end
    if rwt > 0 then
        params.raceWideLineTrafficBlend = rwt
        local s = tonumber(cfg.raceWideLineLateralStartM)
        params.raceWideLineLateralStartM = (s ~= nil and s > 0) and s or (tonumber(DEFAULT_CONFIG.raceWideLineLateralStartM) or 0.9)
        local e = tonumber(cfg.raceWideLineLateralEndM)
        params.raceWideLineLateralEndM = (e ~= nil and e > 0) and e or (tonumber(DEFAULT_CONFIG.raceWideLineLateralEndM) or 2.6)
    end
    local rur = tonumber(cfg.raceWideLineUndersteerRelax)
    if rur == nil then rur = tonumber(DEFAULT_CONFIG.raceWideLineUndersteerRelax) or 0.45 end
    if rur > 0 then
        params.raceWideLineUndersteerRelax = rur
        if not params.raceWideLineLateralStartM then
            params.raceWideLineLateralStartM = tonumber(cfg.raceWideLineLateralStartM) or tonumber(DEFAULT_CONFIG.raceWideLineLateralStartM) or 0.9
            params.raceWideLineLateralEndM = tonumber(cfg.raceWideLineLateralEndM) or tonumber(DEFAULT_CONFIG.raceWideLineLateralEndM) or 2.6
        end
    end
    local floor = tonumber(cfg.raceThrottleFloor)
    if floor ~= nil and floor > 0 and floor < 1 then
        params.raceThrottleFloor = floor
        local hi = tonumber(cfg.raceHighSpeedThreshold)
        if hi ~= nil and hi > 0 then
            params.raceHighSpeedThreshold = hi
            local hif = tonumber(cfg.raceHighSpeedThrottleFloor)
            if hif ~= nil and hif > 0 and hif < 1 then
                params.raceHighSpeedThrottleFloor = hif
            end
        end
    end
    local rcl = tonumber(cfg.raceCornerLineLiftMaxM)
    if rcl == nil then rcl = tonumber(DEFAULT_CONFIG.raceCornerLineLiftMaxM) or 0.22 end
    if rcl > 0 then
        params.raceCornerLineLiftMaxM = rcl
        params.raceCornerCurvStart = tonumber(cfg.raceCornerCurvStart) or tonumber(DEFAULT_CONFIG.raceCornerCurvStart) or 0.022
        params.raceCornerCurvEnd = tonumber(cfg.raceCornerCurvEnd) or tonumber(DEFAULT_CONFIG.raceCornerCurvEnd) or 0.10
        local rcs = tonumber(cfg.raceCornerLineLiftScale)
        if rcs ~= nil then params.raceCornerLineLiftScale = rcs end
    end
    local rtp = tonumber(cfg.raceTrafficPassBlend)
    if rtp == nil then rtp = tonumber(DEFAULT_CONFIG.raceTrafficPassBlend) end
    if rtp ~= nil then params.raceTrafficPassBlend = clamp(rtp, 0, 0.88) end
    local rcsm = tonumber(cfg.raceClearanceScaleMin)
    if rcsm == nil then rcsm = tonumber(DEFAULT_CONFIG.raceClearanceScaleMin) end
    if rcsm ~= nil then params.raceClearanceScaleMin = clamp(rcsm, 0.22, 0.95) end
    local rasm = tonumber(cfg.raceAltPlanSpeedMargin)
    if rasm == nil then rasm = tonumber(DEFAULT_CONFIG.raceAltPlanSpeedMargin) end
    if rasm ~= nil and rasm > 0 then params.raceAltPlanSpeedMargin = rasm end
    local ratm = tonumber(cfg.raceAltPlanTimeMargin)
    if ratm == nil then ratm = tonumber(DEFAULT_CONFIG.raceAltPlanTimeMargin) end
    if ratm ~= nil and ratm > 0 then params.raceAltPlanTimeMargin = ratm end
    local racs = tonumber(cfg.raceAwarenessCoefScale)
    if racs == nil then racs = tonumber(DEFAULT_CONFIG.raceAwarenessCoefScale) end
    if racs ~= nil and racs > 0 then params.raceAwarenessCoefScale = racs end
    local rbd = tonumber(cfg.raceBlockedAheadDistMax)
    if rbd == nil then rbd = tonumber(DEFAULT_CONFIG.raceBlockedAheadDistMax) end
    if rbd ~= nil and rbd > 2 then params.raceBlockedAheadDistMax = rbd end
    local rcg = tonumber(cfg.raceClearancePassMinGainM)
    if rcg == nil then rcg = tonumber(DEFAULT_CONFIG.raceClearancePassMinGainM) end
    if rcg ~= nil and rcg >= 0 then params.raceClearancePassMinGainM = rcg end
    local rct = tonumber(cfg.raceClearancePassTrafficEps)
    if rct == nil then rct = tonumber(DEFAULT_CONFIG.raceClearancePassTrafficEps) end
    if rct ~= nil and rct >= 0 then params.raceClearancePassTrafficEps = rct end
    local rbg = tonumber(cfg.raceBrakeGain)
    if rbg == nil then rbg = tonumber(DEFAULT_CONFIG.raceBrakeGain) end
    if rbg ~= nil then params.raceBrakeGain = clamp(rbg, 0.35, 1.25) end
    local rcgu = tonumber(cfg.raceCornerGripUtil)
    if rcgu == nil then rcgu = tonumber(DEFAULT_CONFIG.raceCornerGripUtil) end
    if rcgu ~= nil and rcgu > 0 then params.raceCornerGripUtil = clamp(rcgu, 1, 1.55) end
    local rcpb = tonumber(cfg.raceCornerPlanBoost)
    if rcpb ~= nil and rcpb > 0 then params.raceCornerPlanBoost = clamp(rcpb, 1, 1.15) end
    if cfg.raceCommitCorners == false then params.raceCommitCorners = false end
    if cfg.raceCornerExitPush == false then params.raceCornerExitPush = false end
    local rceg = tonumber(cfg.raceCornerExitPushMinGain)
    if rceg ~= nil and rceg >= 0 then params.raceCornerExitPushMinGain = clamp(rceg, 0, 4) end
    local rceo = tonumber(cfg.raceCornerExitPushOvershoot)
    if rceo ~= nil and rceo > 0 then params.raceCornerExitPushOvershoot = clamp(rceo, 1, 1.08) end
    local rcer = tonumber(cfg.raceCornerExitPushRiseRate)
    if rcer ~= nil and rcer > 0 then params.raceCornerExitPushRiseRate = clamp(rcer, 4, 40) end
    local rces = tonumber(cfg.raceCornerExitPushSlipMax)
    if rces ~= nil and rces > 0 then params.raceCornerExitPushSlipMax = clamp(rces, 0.6, 1.2) end
    local rus = tonumber(cfg.raceUndersteerSlipMin)
    if rus ~= nil and rus > 0 then params.raceUndersteerSlipMin = clamp(rus, 0.5, 1.6) end
    local rgr = tonumber(cfg.raceGripLiveRiseRate)
    if rgr ~= nil and rgr > 0 then params.raceGripLiveRiseRate = rgr end
    local rcto = tonumber(cfg.raceCommitTargetOvershoot)
    if rcto ~= nil and rcto > 0 then params.raceCommitTargetOvershoot = clamp(rcto, 1, 1.2) end
    local rcsp = tonumber(cfg.raceCommitSpeedFloorPct)
    if rcsp ~= nil and rcsp > 0 then params.raceCommitSpeedFloorPct = clamp(rcsp, 0.9, 1) end
    local rst = tonumber(cfg.raceSlipTarget)
    if rst ~= nil and rst > 0 then params.raceSlipTarget = clamp(rst, 0.9, 1.4) end
    local rsg = tonumber(cfg.raceSlipGain)
    if rsg ~= nil and rsg > 0 then params.raceSlipGain = clamp(rsg, 0.1, 0.6) end
    local rfm = tonumber(cfg.raceFrictionMult)
    if rfm ~= nil and rfm > 0 then params.raceFrictionMult = clamp(rfm, 1, 1.15) end
    return params
end

-- Freeze or unfreeze the player vehicle (e.g. during countdown until GO, same moment as AI release). Uses same pattern as bus.lua.
function M.setPlayerFreeze(freeze)
    if not core_vehicleBridge or not core_vehicleBridge.executeAction then return end
    local veh = be and be:getPlayerVehicle(0)
    if veh then
        core_vehicleBridge.executeAction(veh, 'setFreeze', freeze and true or false)
    end
end

local function getObjectSpeedMps(vehId)
    if not be or not be.getObjectVelocityXYZ or not vehId then return 0 end
    local v = be:getObjectVelocityXYZ(vehId)
    if type(v) == "number" then
        return math.abs(v)
    end
    if type(v) == "table" then
        local x = v.x or v[1] or 0
        local y = v.y or v[2] or 0
        local z = v.z or v[3] or 0
        return math.sqrt(x * x + y * y + z * z)
    end
    return 0
end

local function isUpsideDown(vehObj)
    if not vehObj or not vehObj.getDirectionVectorUp then return false end
    local up = vehObj:getDirectionVectorUp()
    if not up then return false end
    local upZ = up.z or up[3] or 0
    return upZ < 0
end

local function resetDelayedDespawnState()
    mDelayedDespawnActive = false
    mDelayedDespawnWaiting = false
    mDelayedDespawnTimer = 0
    mDelayedDespawnStaggerSeconds = 4.0
end

cancelDelayedDespawn = function()
    if not mDelayedDespawnActive then return end
    resetDelayedDespawnState()
end

queueEngineStart = function(vehObj)
    if not vehObj then return end
    -- One-shot ignition command to avoid visible restart cycling.
    if core_vehicleBridge and core_vehicleBridge.executeAction then
        pcall(function()
            core_vehicleBridge.executeAction(vehObj, 'setIgnitionLevel', 3)
        end)
    end
    vehObj:queueLuaCommand("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end")
end

local function despawnSingleVehicle()
    local vehId = mSpawnedAiVehicleIds[1]
    if not vehId then return false end
    local obj = be:getObjectByID(vehId)
    if obj then
        if mDnfCallback then pcall(mDnfCallback, vehId) end
        obj:delete()
        table.remove(mSpawnedAiVehicleIds, 1)
        mEverSpawnedAiVehicleIdsSweep[vehId] = nil
        mRecoveryStateByVehId[vehId] = nil
        mRetiredUpsideDownByVehId[vehId] = nil
        mVehicleLaneIndexByVehId[vehId] = nil
        mNavStateByVehId[vehId] = nil
        return true
    end
    -- Transient nil object: drop this slot anyway so the delayed-despawn job can progress, but preserve
    -- the sweep-set entry so clearSpawned() will retry deletion if the vehicle resurfaces.
    log("W", "aiRacers", string.format(
        "despawnSingleVehicle: deleting bookkeeping for vehId %s (getObjectByID returned nil); sweep set retains entry",
        tostring(vehId)
    ))
    table.remove(mSpawnedAiVehicleIds, 1)
    mRecoveryStateByVehId[vehId] = nil
    mRetiredUpsideDownByVehId[vehId] = nil
    mVehicleLaneIndexByVehId[vehId] = nil
    mNavStateByVehId[vehId] = nil
    return true
end

local function updateDelayedDespawn(step)
    if not mDelayedDespawnActive then return false end
    if #mSpawnedAiVehicleIds == 0 then
        resetDelayedDespawnState()
        mRecoveryMonitorEnabled = false
        return true
    end
    mDelayedDespawnTimer = (mDelayedDespawnTimer or 0) - step
    if mDelayedDespawnTimer > 0 then
        return true
    end
    if mDelayedDespawnWaiting then
        mDelayedDespawnWaiting = false
        mDelayedDespawnTimer = mDelayedDespawnStaggerSeconds
        return true
    end
    despawnSingleVehicle()
    if #mSpawnedAiVehicleIds == 0 then
        resetDelayedDespawnState()
        mRecoveryMonitorEnabled = false
        mRecoveryStateByVehId = {}
        mRetiredUpsideDownByVehId = {}
        mVehicleLaneIndexByVehId = {}
        mNavStateByVehId = {}
        mActiveRaceForRecovery = nil
        mActiveLapCountForRecovery = 1
    else
        mDelayedDespawnTimer = mDelayedDespawnStaggerSeconds
    end
    return true
end

local function despawnAiVehiclesById(toDespawn)
    if type(toDespawn) ~= "table" or next(toDespawn) == nil then return end
    for i = #mSpawnedAiVehicleIds, 1, -1 do
        local vehId = mSpawnedAiVehicleIds[i]
        if toDespawn[vehId] then
            local obj = be:getObjectByID(vehId)
            if obj then
                -- Resolvable — fire DNF and fully despawn, dropping all bookkeeping.
                if mDnfCallback then pcall(mDnfCallback, vehId) end
                obj:delete()
                table.remove(mSpawnedAiVehicleIds, i)
                mEverSpawnedAiVehicleIdsSweep[vehId] = nil
                mRecoveryStateByVehId[vehId] = nil
                mRetiredUpsideDownByVehId[vehId] = nil
                mVehicleLaneIndexByVehId[vehId] = nil
                mNavStateByVehId[vehId] = nil
            else
                -- Transient: be:getObjectByID returned nil (often during hard-crash physics states).
                -- Do NOT drop the id or fire DNF; leave the slot for the recovery monitor to re-evaluate
                -- next tick. Orphan sweep in clearSpawned() will catch it if it never resolves.
                log("W", "aiRacers", string.format(
                    "despawnAiVehiclesById: deferring delete for vehId %s (getObjectByID returned nil)",
                    tostring(vehId)
                ))
            end
        end
    end
end

local function buildNavWpTargetListFromPath(path)
    if not path or #path < 2 then return nil end
    if not map or not map.findClosestRoad then return nil end
    local wpTargetList = {}
    local seenConsecutive = nil
    -- Denser path (was 50) so AI follows track smoothly and does not cut between sparse waypoints.
    local step = math.max(1, math.floor(#path / 120))
    for i = 1, #path, step do
        local node = path[i]
        if node and node.x and node.y and node.z then
            local _, nodeIdx = map.findClosestRoad(vec3(node.x, node.y, node.z))
            if nodeIdx and nodeIdx ~= seenConsecutive then
                table.insert(wpTargetList, nodeIdx)
                seenConsecutive = nodeIdx
            end
        end
    end
    local lastNode = path[#path]
    if lastNode and lastNode.x and lastNode.y and lastNode.z then
        local _, lastNodeIdx = map.findClosestRoad(vec3(lastNode.x, lastNode.y, lastNode.z))
        if lastNodeIdx and lastNodeIdx ~= seenConsecutive then
            table.insert(wpTargetList, lastNodeIdx)
        end
    end
    if #wpTargetList < 2 then return nil end
    return wpTargetList
end

local function getMapNodePos(mapData, nodeId)
    if not mapData or not mapData.nodes then return nil end
    local n = mapData.nodes[nodeId]
    if not n or not n.pos then return nil end
    return vec3(n.pos)
end

local function orientWpTargetListForVehicle(wpTargetList, vehObj)
    if not wpTargetList or #wpTargetList < 2 or not vehObj then return wpTargetList end
    if not map or not map.getMap then return wpTargetList end
    local mapData = map.getMap()
    if not mapData or not mapData.nodes then return wpTargetList end
    local vpos = vehObj:getPosition()
    if not vpos then return wpTargetList end

    local nearestIdx, nearestDist = 1, math.huge
    for i, nodeId in ipairs(wpTargetList) do
        local npos = getMapNodePos(mapData, nodeId)
        if npos then
            local dx = (npos.x or 0) - (vpos.x or 0)
            local dy = (npos.y or 0) - (vpos.y or 0)
            local dz = (npos.z or 0) - (vpos.z or 0)
            local d = dx * dx + dy * dy + dz * dz
            if d < nearestDist then
                nearestDist = d
                nearestIdx = i
            end
        end
    end

    local rotated = {}
    for i = nearestIdx, #wpTargetList do
        rotated[#rotated + 1] = wpTargetList[i]
    end
    for i = 1, nearestIdx - 1 do
        rotated[#rotated + 1] = wpTargetList[i]
    end

    local vdir = vehObj.getDirectionVector and vehObj:getDirectionVector() or nil
    if vdir and #rotated >= 3 then
        local p0 = getMapNodePos(mapData, rotated[1])
        local pNext = getMapNodePos(mapData, rotated[2])
        local pPrev = getMapNodePos(mapData, rotated[#rotated])
        if p0 and pNext and pPrev then
            local toNext = pNext - p0
            local toPrev = pPrev - p0
            local nextLen = toNext:length()
            local prevLen = toPrev:length()
            if nextLen > 0.001 and prevLen > 0.001 then
                toNext = toNext / nextLen
                toPrev = toPrev / prevLen
                local dotNext = (vdir.x or 0) * (toNext.x or 0) + (vdir.y or 0) * (toNext.y or 0) + (vdir.z or 0) * (toNext.z or 0)
                local dotPrev = (vdir.x or 0) * (toPrev.x or 0) + (vdir.y or 0) * (toPrev.y or 0) + (vdir.z or 0) * (toPrev.z or 0)
                if dotNext < dotPrev then
                    local reversed = { rotated[1] }
                    for i = #rotated, 2, -1 do
                        reversed[#reversed + 1] = rotated[i]
                    end
                    rotated = reversed
                end
            end
        end
    end

    return rotated
end

local function queueNavDriveForVehicle(vehObj, path, noOfLaps, cfg, race)
    if not vehObj or not path or #path < 2 then return false end
    local wpTargetList = buildNavWpTargetListFromPath(path)
    if not wpTargetList or #wpTargetList < 2 then return false end
    wpTargetList = orientWpTargetListForVehicle(wpTargetList, vehObj)
    if not wpTargetList or #wpTargetList < 2 then return false end
    if wpTargetList[#wpTargetList] ~= wpTargetList[1] then
        wpTargetList[#wpTargetList + 1] = wpTargetList[1]
    end
    local wpTargetListStr = serialize(wpTargetList)
    local aggression = tonumber(cfg.aggression) or 1.0
    local driveInLane = tostring(cfg.driveInLane or DEFAULT_CONFIG.driveInLane)
    local avoidCars = tostring(cfg.avoidCars or DEFAULT_CONFIG.avoidCars)
    local targetSpeedSmootherRate = tonumber(cfg.targetSpeedSmootherRate) or DEFAULT_CONFIG.targetSpeedSmootherRate or 18
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")

    -- setParameters (raceAccelScale / raceThrottleKp from cfg), setAggression, setRacing, setAvoidCars, then driveUsingPath.
    if cfg.useRacingParameters ~= false and DEFAULT_CONFIG.useRacingParameters ~= false then
        local params = getRacingParameters(cfg, race)
        vehObj:queueLuaCommand('ai.setParameters(' .. serialize(params) .. ')')
    end
    vehObj:queueLuaCommand('ai.setAggression(' .. tostring(aggression) .. ')')
    vehObj:queueLuaCommand('ai.setRacing(true)')
    vehObj:queueLuaCommand('ai.setAvoidCars("' .. avoidCars .. '")')

    vehObj:queueLuaCommand([[
        local wpTargetList = ]] .. wpTargetListStr .. [[
        local noOfLaps = ]] .. tostring(noOfLaps) .. [[
        if wpTargetList and #wpTargetList > 1 and ai and ai.driveUsingPath then
            ai.driveUsingPath({
                wpTargetList = wpTargetList,
                avoidCars = ']] .. avoidCars .. [[',
                driveInLane = ']] .. driveInLane .. [[',
                aggression = ]] .. tostring(aggression) .. [[,
                noOfLaps = noOfLaps,
                targetSpeedSmootherRate = ]] .. tostring(targetSpeedSmootherRate) .. [[
            })
        end
    ]])
    return true
end

local function queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
    if not vehObj or not race then return end
    local pathKey = getRacePathKey(race)
    if not pathKey then return end
    if type(laneIndex) == "number" and race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table" and #race.checkpointRoadLanes > 0 then
        pathKey = pathKey .. "_lane_" .. tostring(laneIndex)
    end
    local path = mPathCache[pathKey]
    if not path or #path == 0 then
        M.preloadPathForRace(race)
        path = mPathCache[pathKey]
    end
    if not path or #path == 0 then return end

    if cfg.useNavgraphPathfinding ~= false then
        if queueNavDriveForVehicle(vehObj, path, noOfLaps, cfg, race) then
            return
        end
    end

    local vpos = vehObj:getPosition()
    local vdir, vup
    if vehObj.getDirectionVector and vehObj.getDirectionVectorUp then
        vdir = vehObj:getDirectionVector()
        vup = vehObj:getDirectionVectorUp()
    end
    local scriptPath = buildScriptPathNoTeleport(path, vpos, vdir, vup)
    if not scriptPath or #scriptPath < 2 then return end

    local pathStr = serialize(scriptPath)
    local aggression = tonumber(cfg.aggression) or 1.0
    local driveInLane = tostring(cfg.driveInLane or DEFAULT_CONFIG.driveInLane)
    local avoidCars = tostring(cfg.avoidCars or DEFAULT_CONFIG.avoidCars)
    local targetSpeedSmootherRate = tonumber(cfg.targetSpeedSmootherRate) or DEFAULT_CONFIG.targetSpeedSmootherRate or 18
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")

    -- setParameters (raceAccelScale / raceThrottleKp from cfg), setAggression, setRacing, setAvoidCars, then driveUsingPath.
    if cfg.useRacingParameters ~= false and DEFAULT_CONFIG.useRacingParameters ~= false then
        local params = getRacingParameters(cfg, race)
        vehObj:queueLuaCommand('ai.setParameters(' .. serialize(params) .. ')')
    end
    vehObj:queueLuaCommand('ai.setAggression(' .. tostring(aggression) .. ')')
    vehObj:queueLuaCommand('ai.setRacing(true)')
    vehObj:queueLuaCommand('ai.setAvoidCars("' .. avoidCars .. '")')

    vehObj:queueLuaCommand([[
        local path = ]] .. pathStr .. [[
        local noOfLaps = ]] .. tostring(noOfLaps) .. [[
        if path and #path > 0 and ai and ai.driveUsingPath then
            ai.driveUsingPath({
                script = path,
                avoidCars = ']] .. avoidCars .. [[',
                driveInLane = ']] .. driveInLane .. [[',
                aggression = ]] .. tostring(aggression) .. [[,
                noOfLaps = noOfLaps,
                targetSpeedSmootherRate = ]] .. tostring(targetSpeedSmootherRate) .. [[
            })
        end
    ]])
end

-- Call at countdown GO: release spawned AI for this race using script path. When race has checkpointRoadLanes, each AI gets a lane path by spawn index (laneIndex = (i-1) % numLanes).
-- Player stays frozen and is unfrozen 0.5s after AI go to account for AI reaction time (slightly behind).
function M.releaseAndDrive(race, lapCount)
    if not race then return end
    local cfg = getMergedConfigForRace(race)
    if cfg.enabled == false then
        M.setPlayerFreeze(false)
        return
    end
    cancelDelayedDespawn()
    M.preloadPathForRace(race)
    local pathKey = getRacePathKey(race)
    if not pathKey then
        M.setPlayerFreeze(false)
        return
    end
    local numLanes = (race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table") and #race.checkpointRoadLanes or 0
    -- Use a high lap count so AI keep lapping after race distance; leaderboard still uses required laps from triggers.
    local requiredLaps = (type(lapCount) == "number" and lapCount > 0) and lapCount or 1
    local noOfLaps = math.max(requiredLaps, 99)
    mActiveRaceForRecovery = race
    mActiveLapCountForRecovery = requiredLaps
    mRecoveryMonitorEnabled = true
    mRecoveryCheckAccumulator = 0
    mRecoveryGraceTimer = math.max(0, tonumber(cfg.launchRecoveryGraceSeconds) or DEFAULT_CONFIG.launchRecoveryGraceSeconds)
    for i, vehId in ipairs(mSpawnedAiVehicleIds) do
        local vehObj = be:getObjectByID(vehId)
        if vehObj then
            if cfg.startEngineOnSpawn ~= false then
                queueEngineStart(vehObj)
            end
            local laneIndex = (numLanes > 0) and ((i - 1) % numLanes) or nil
            mVehicleLaneIndexByVehId[vehId] = laneIndex
            queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
        end
    end
    local proxyRide = gameplay_events_freeroam_competitiveTrackFlow and
        gameplay_events_freeroam_competitiveTrackFlow.isRacingTeamProxyRaceSessionActive and
        gameplay_events_freeroam_competitiveTrackFlow.isRacingTeamProxyRaceSessionActive()
    if not proxyRide then
        mPlayerUnfreezeAt = os.clock() + 0.5
        M.setPlayerFreeze(true)
    end
end

--- Same path AI as grid rivals, for the player vehicle during racing-team ride-along (input locked separately).
function M.driveVehicleOnRacePath(vehId, race, lapCount, laneIndex)
    if not vehId or not race then
        return
    end
    local cfg = getMergedConfigForRace(race)
    if not cfg or cfg.enabled == false then
        return
    end
    M.preloadPathForRace(race)
    local requiredLaps = (type(lapCount) == "number" and lapCount > 0) and lapCount or 1
    local noOfLaps = math.max(requiredLaps, 99)
    local vehObj = be and be.getObjectByID and be:getObjectByID(vehId)
    if not vehObj then
        return
    end
    if cfg.startEngineOnSpawn ~= false then
        queueEngineStart(vehObj)
    end
    mVehicleLaneIndexByVehId[vehId] = laneIndex

    setPlayersAiParams(cfg)
    queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
end

function M.onUpdate(dtReal)
    local dt = tonumber(dtReal) or 0
    if dt <= 0 then return end

    if type(pendingPowerCallback) == "function" and pendingPowerVehId and pendingPowerRequestGen > 0 then
        local now = os.clock()
        local activeGen = pendingPowerRequestGen
        if pendingPowerRequestDeadline and now > pendingPowerRequestDeadline then
            if activeGen == pendingPowerRequestGen then
                M.onPlayerVehiclePowerWeight(0, nil)
            end
        elseif M._powerRequestUiFallbackTimer and (now - M._powerRequestUiFallbackTimer) > 1.5 then
            if activeGen == pendingPowerRequestGen then
                M._powerRequestUiFallbackTimer = nil
                local vehObj = be and be:getObjectByID(pendingPowerVehId)
                if vehObj and vehObj.queueLuaCommand then
                    vehObj:queueLuaCommand(string.format(M._powerRequestScriptTemplate, 0, POWER_REQUEST_MAX_RETRIES, activeGen))
                else
                    M.onPlayerVehiclePowerWeight(0, nil)
                end
            end
        end
    end

    if mPlayerUnfreezeAt and os.clock() >= mPlayerUnfreezeAt then
        mPlayerUnfreezeAt = nil
        M.setPlayerFreeze(false)
    end

    if updateDelayedDespawn(dt) then
        return
    end

    if not mRecoveryMonitorEnabled then return end
    if not mSpawnedAiVehicleIds or #mSpawnedAiVehicleIds == 0 then return end
    if not mActiveRaceForRecovery then return end
    if DISABLE_AI_RACE_RECOVERY_FOR_TEST then
        return
    end

    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return end
    -- When false, do not despawn any AI for stuck/wreck during race; only post-race cleanup runs.
    if cfg.despawnWreckedDuringRace == false then return end
    if mRecoveryGraceTimer and mRecoveryGraceTimer > 0 then
        mRecoveryGraceTimer = math.max(0, mRecoveryGraceTimer - dt)
        return
    end

    mRecoveryCheckAccumulator = mRecoveryCheckAccumulator + dt
    if mRecoveryCheckAccumulator < 0.2 then return end
    local step = mRecoveryCheckAccumulator
    mRecoveryCheckAccumulator = 0

    local recoveryEnabled = cfg.recoveryEnabled ~= false
    local speedThreshold = math.max(0, tonumber(cfg.recoverySpeedThresholdMps) or DEFAULT_CONFIG.recoverySpeedThresholdMps)
    local stuckSeconds = math.max(0.5, tonumber(cfg.recoveryStuckSeconds) or DEFAULT_CONFIG.recoveryStuckSeconds)
    local cooldownSeconds = math.max(1, tonumber(cfg.recoveryCooldownSeconds) or DEFAULT_CONFIG.recoveryCooldownSeconds)
    local despawnEnabled = cfg.despawnWreckedEnabled ~= false
    local upsideDownDespawnSeconds = math.max(2, tonumber(cfg.despawnUpsideDownSeconds) or DEFAULT_CONFIG.despawnUpsideDownSeconds)
    local despawnAfterRecoveries = math.max(1, tonumber(cfg.despawnAfterRecoveries) or DEFAULT_CONFIG.despawnAfterRecoveries)
    local terminalStuckSeconds = math.max(stuckSeconds, tonumber(cfg.despawnTerminalStuckSeconds) or DEFAULT_CONFIG.despawnTerminalStuckSeconds)
    local alwaysStuckSeconds = math.max(terminalStuckSeconds, tonumber(cfg.despawnAlwaysStuckSeconds) or DEFAULT_CONFIG.despawnAlwaysStuckSeconds)
    local toDespawn = {}

    for _, vehId in ipairs(mSpawnedAiVehicleIds) do
        local vehObj = be:getObjectByID(vehId)
        if vehObj then
            local state = mRecoveryStateByVehId[vehId] or {
                stuckTime = 0,
                cooldown = 0,
                recoveries = 0,
                upsideDownTime = 0,
                terminalStuckTime = 0,
                alwaysStuckTime = 0
            }
            local upsideDown = isUpsideDown(vehObj)
            if upsideDown then
                state.upsideDownTime = (state.upsideDownTime or 0) + step
                mRetiredUpsideDownByVehId[vehId] = true
                vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                if despawnEnabled and state.upsideDownTime >= upsideDownDespawnSeconds then
                    toDespawn[vehId] = true
                end
                state.stuckTime = 0
                state.terminalStuckTime = 0
                state.alwaysStuckTime = 0
                mRecoveryStateByVehId[vehId] = state
            else
                state.upsideDownTime = 0
                if not mRetiredUpsideDownByVehId[vehId] then
                    state.cooldown = math.max(0, (state.cooldown or 0) - step)

                    local speed = getObjectSpeedMps(vehId)
                    if speed <= speedThreshold then
                        state.stuckTime = (state.stuckTime or 0) + step
                        state.terminalStuckTime = (state.terminalStuckTime or 0) + step
                        state.alwaysStuckTime = (state.alwaysStuckTime or 0) + step
                    else
                        state.stuckTime = 0
                        state.terminalStuckTime = 0
                        state.alwaysStuckTime = 0
                    end

                    if recoveryEnabled and state.stuckTime >= stuckSeconds and state.cooldown <= 0 then
                        vehObj:queueLuaCommand([[
                            if recovery then
                                recovery.startRecovering()
                                recovery.stopRecovering()
                            end
                        ]])
                        queueDriveForVehicle(vehObj, mActiveRaceForRecovery, mActiveLapCountForRecovery, cfg, mVehicleLaneIndexByVehId[vehId])
                        state.recoveries = (state.recoveries or 0) + 1
                        state.stuckTime = 0
                        state.cooldown = cooldownSeconds
                    end

                    if despawnEnabled and (state.recoveries or 0) >= despawnAfterRecoveries and (state.terminalStuckTime or 0) >= terminalStuckSeconds then
                        toDespawn[vehId] = true
                    end
                    if despawnEnabled and (state.alwaysStuckTime or 0) >= alwaysStuckSeconds then
                        toDespawn[vehId] = true
                    end
                end
                mRecoveryStateByVehId[vehId] = state
            end
        end
    end

    despawnAiVehiclesById(toDespawn)
end

function M.scheduleDelayedDespawn(delaySeconds, staggerSeconds)
    if not mSpawnedAiVehicleIds or #mSpawnedAiVehicleIds == 0 then
        resetDelayedDespawnState()
        return 0
    end
    local cfg = getCurrentLevelConfig()
    local delay = tonumber(delaySeconds)
    if not delay then
        delay = tonumber(cfg.delayedDespawnDefaultSeconds) or DEFAULT_CONFIG.delayedDespawnDefaultSeconds
    end
    local stagger = tonumber(staggerSeconds)
    if not stagger then
        stagger = tonumber(cfg.delayedDespawnStaggerSeconds) or DEFAULT_CONFIG.delayedDespawnStaggerSeconds
    end
    mDelayedDespawnActive = true
    mDelayedDespawnWaiting = true
    mDelayedDespawnTimer = math.max(0, delay)
    mDelayedDespawnStaggerSeconds = math.max(0.25, stagger)
    mRecoveryMonitorEnabled = false
    mRecoveryCheckAccumulator = 0
    return #mSpawnedAiVehicleIds
end

-- One-shot ignition pass for all currently spawned AI (used during staging pre-countdown).
function M.startEnginesForSpawned()
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    local started = 0
    for _, vehId in ipairs(mSpawnedAiVehicleIds) do
        local obj = be:getObjectByID(vehId)
        if obj then
            queueEngineStart(obj)
            started = started + 1
        end
    end
    return started
end

-- Return list of spawned AI vehicle IDs (for start trigger to count AI laps).
function M.getSpawnedVehicleIds()
    return mSpawnedAiVehicleIds
end

function M.getLastSpawnedLineupSnapshot()
    return copyLineupSnapshot(mLastSpawnedAiLineupSnapshot)
end

function M.spawnForStagingWithExactLineup(raceName, race, facilityName, lineup)
    if type(lineup) ~= "table" or #lineup == 0 then
        return 0
    end
    local sanitized = {}
    for _, row in ipairs(lineup) do
        if type(row) == "table" and type(row.model) == "string" and row.model ~= ""
            and type(row.config) == "string" and row.config ~= "" then
            table.insert(sanitized, {
                model = row.model,
                config = row.config,
                matchPw = tonumber(row.matchPw) or tonumber(row.powerHp) or nil,
            })
        end
    end
    if #sanitized == 0 then
        return 0
    end
    return spawnWithModelConfigList(raceName, race, facilityName, sanitized)
end

function M.setDnfCallback(cb)
    mDnfCallback = cb
end

-- Clear spawned AI vehicles (e.g. when race is exited or session cleared). Call from competitiveRaceManager.exitRace.
-- Iterates the union of the active list and the orphan sweep set so wrecks that were dropped from the
-- active list without being destroyed (e.g. transient be:getObjectByID nil during a crash) are caught.
function M.clearSpawned()
    local activeSet = {}
    for _, vehId in ipairs(mSpawnedAiVehicleIds) do
        activeSet[vehId] = true
    end
    local union = {}
    for vehId in pairs(activeSet) do union[vehId] = true end
    for vehId in pairs(mEverSpawnedAiVehicleIdsSweep) do union[vehId] = true end
    local orphansDeleted = 0
    for vehId in pairs(union) do
        if mDnfCallback then pcall(mDnfCallback, vehId) end
        local obj = be:getObjectByID(vehId)
        if obj then
            obj:delete()
            if not activeSet[vehId] then
                orphansDeleted = orphansDeleted + 1
            end
        end
    end
    if orphansDeleted > 0 then
        log("W", "aiRacers", string.format(
            "clearSpawned: swept %d orphan AI vehicle(s) that had been dropped from the active list without deletion",
            orphansDeleted
        ))
    end
    mSpawnedAiVehicleIds = {}
    mEverSpawnedAiVehicleIdsSweep = {}
    mRecoveryStateByVehId = {}
    mRetiredUpsideDownByVehId = {}
    mVehicleLaneIndexByVehId = {}
    mNavStateByVehId = {}
    mRecoveryMonitorEnabled = false
    mRecoveryCheckAccumulator = 0
    mActiveRaceForRecovery = nil
    mActiveLapCountForRecovery = 1
    mRecoveryGraceTimer = 0
    resetDelayedDespawnState()
end

function M.invalidateConfigCache()
    -- no-op: config is read from disk each time getCurrentLevelConfig() is called
end

-- HP reading and class eligibility for player (race staging).
-- Class order and max HP per class (player eligible if vehicle power <= eligibilityPct * classMax).
local CLASS_ORDER = { "D", "C", "B", "A" }
local CLASS_MAX_HP = { D = 160, C = 370, B = 600, A = 9999 }
local ELIGIBILITY_PCT = 0.75
-- XP thresholds: at least this much business XP to be in that class (D=0, C=1500, B=5000, A=15000).
local XP_FOR_CLASS = { D = 0, C = 1500, B = 5000, A = 15000 }

-- Fresh live sample (from vehicle VM): HP + weight → hp/kg for staging UI and podium cap.
local mCachedLivePlayerHp = nil
local mCachedLivePlayerWeightKg = nil
local mCachedLivePlayerPw = nil
local mCachedLivePlayerVehId = nil
local mCachedLivePlayerClock = nil
local LIVE_HP_CACHE_STALE_SEC = 90

local function invalidateLiveHpCacheIfVehicleChanged()
    if not be or not be.getPlayerVehicleID then return end
    local pid = be:getPlayerVehicleID(0)
    if not pid or not mCachedLivePlayerVehId or pid ~= mCachedLivePlayerVehId then
        mCachedLivePlayerHp = nil
        mCachedLivePlayerWeightKg = nil
        mCachedLivePlayerPw = nil
        mCachedLivePlayerVehId = nil
        mCachedLivePlayerClock = nil
    end
end

local function liveHpSampleIsTrusted()
    invalidateLiveHpCacheIfVehicleChanged()
    if type(mCachedLivePlayerHp) ~= "number" or mCachedLivePlayerHp <= 0 then return false end
    if not mCachedLivePlayerClock then return false end
    local clk = (os and os.clock) and os.clock() or 0
    return (clk - mCachedLivePlayerClock) < LIVE_HP_CACHE_STALE_SEC
end

local function storeLivePowerSampleForVehicle(vehId, powerWatts, weightKg)
    if not vehId or not be or not be.getPlayerVehicleID or vehId ~= be:getPlayerVehicleID(0) then return end
    if type(powerWatts) ~= "number" or powerWatts <= 0 then return end
    local hp = powerWattsToHp(powerWatts)
    if type(hp) ~= "number" or hp <= 0 then return end
    mCachedLivePlayerHp = hp
    mCachedLivePlayerWeightKg = tonumber(weightKg)
    if mCachedLivePlayerWeightKg and mCachedLivePlayerWeightKg > 0 then
        mCachedLivePlayerPw = hpPerKgFromHpAndWeightKg(hp, mCachedLivePlayerWeightKg)
    else
        mCachedLivePlayerPw = nil
    end
    mCachedLivePlayerVehId = vehId
    mCachedLivePlayerClock = os.clock()
end
-- Vehicle script: max maxPower over all "engine" devices (raw may be HP-scale or watts; GE normalizes in onPlayerVehiclePowerWeight), beam stats weight, both required before success.
-- Retries until power>0 and weight>0 or max retries (then report last values).
M._powerRequestScriptTemplate = [[
local retry = %d
local maxR = %d
local reqGen = %d
local power, weight = 0, 0
local engines = powertrain.getDevicesByCategory("engine")
if engines then
  for _, eng in ipairs(engines) do
    if eng and eng.maxPower then
      local mp = eng.maxPower or 0
      if mp > power then power = mp end
    end
  end
end
local stats = obj:calcBeamStats()
if stats and stats.total_weight then weight = stats.total_weight end
local ready = power > 0 and weight > 0
if ready or retry >= maxR then
  obj:queueGameEngineLua("(function() local g = _G.career_modules_competitiveRace_aiRacers if g and type(g.onPlayerVehiclePowerWeight) == \"function\" then g.onPlayerVehiclePowerWeight(" .. tostring(power) .. "," .. tostring(weight) .. "," .. tostring(reqGen) .. ") end end)()")
else
  obj:queueGameEngineLua("(function() local g = _G.career_modules_competitiveRace_aiRacers if g and type(g.onPlayerVehiclePowerWeightRetry) == \"function\" then g.onPlayerVehiclePowerWeightRetry(" .. tostring(retry) .. "," .. tostring(reqGen) .. ") end end)()")
end
]]

-- One-shot VM read for staging UI refresh; does not use pendingPowerCallback (safe alongside AI spawn).
M._livePowerCacheScript = [[
local power, weight = 0, 0
local engines = powertrain.getDevicesByCategory("engine")
if engines then
  for _, eng in ipairs(engines) do
    if eng and eng.maxPower then
      local mp = eng.maxPower or 0
      if mp > power then power = mp end
    end
  end
end
local stats = obj:calcBeamStats()
if stats and stats.total_weight then weight = stats.total_weight end
if power > 0 and weight > 0 then
  local vid = obj:getID()
  obj:queueGameEngineLua("(function() local g=_G.career_modules_competitiveRace_aiRacers if g and type(g.ingestLivePowerCacheSample)==\"function\" then g.ingestLivePowerCacheSample(" .. tostring(vid) .. "," .. tostring(power) .. "," .. tostring(weight) .. ") end end)()")
end
]]

local function getEffectiveClassFromXp(cfg, businessXp)
    local xp = tonumber(businessXp) or 0
    local class = "D"
    for i = #CLASS_ORDER, 1, -1 do
        local c = CLASS_ORDER[i]
        local threshold = (cfg and cfg.horsepowerClassXp and cfg.horsepowerClassXp[c]) or XP_FOR_CLASS[c]
        if xp >= (tonumber(threshold) or 0) then
            class = c
            break
        end
    end
    return class
end

local function getEligibilityThresholdForClass(cfg, class)
    local maxHp = (cfg and cfg.horsepowerClassRanges and cfg.horsepowerClassRanges[class]) or CLASS_MAX_HP[class]
    local pct = (cfg and cfg.eligibilityPct) or ELIGIBILITY_PCT
    if not maxHp then return nil end
    return math.floor((tonumber(maxHp) or 0) * (tonumber(pct) or ELIGIBILITY_PCT))
end

-- Returns player vehicle model key and config key (e.g. "etkc", "default") or nil, nil if not available.
function M.getPlayerVehicleModelAndConfig()
    if not be or not be.getPlayerVehicleID then return nil, nil end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return nil, nil end
    if not core_vehicles or not core_vehicles.getVehicleDetails then return nil, nil end
    local details = core_vehicles.getVehicleDetails(vehId)
    if not details or not details.current then return nil, nil end
    local modelKey = details.current.key
    local configKey = details.current.config_key or "default"
    return modelKey, configKey
end

-- GE entry from vehicle VM: updates live HP cache only (no pendingPowerCallback).
function M.ingestLivePowerCacheSample(vid, powerRaw, weightRaw)
    vid = tonumber(vid)
    if not vid or not be or not be.getPlayerVehicleID or vid ~= be:getPlayerVehicleID(0) then return end
    local pRaw = tonumber(powerRaw)
    local wRaw = tonumber(weightRaw)
    if not pRaw or not wRaw or wRaw <= 0 then return end
    local p = liveMaxPowerRawToWatts(pRaw)
    if not p or p <= 0 then return end
    storeLivePowerSampleForVehicle(vid, p, wRaw)
end

-- Staging UI: prefer fresh live sample; fall back to sync getVehicleDetails (display only).
function M.getPlayerVehiclePowerForStagingUi()
    if liveHpSampleIsTrusted() then
        return mCachedLivePlayerHp, "live"
    end
    return M.getPlayerVehiclePower(), "sync"
end

function M.getPlayerVehiclePwForStagingUi()
    if liveHpSampleIsTrusted() and type(mCachedLivePlayerPw) == "number" and mCachedLivePlayerPw > 0 then
        return mCachedLivePlayerPw, "live"
    end
    return select(1, M.getPlayerVehiclePowerAndClass()), "sync"
end

-- Podium class cap (legacy HP): trusted live HP only.
function M.getPlayerVehiclePowerForPodiumCapCheck()
    if liveHpSampleIsTrusted() then
        return mCachedLivePlayerHp
    end
    return nil
end

--- Sanctioned podium: trusted live hp/kg only (requires power + weight in cache).
function M.getPlayerVehiclePwForPodiumCapCheck()
    if liveHpSampleIsTrusted() and type(mCachedLivePlayerPw) == "number" and mCachedLivePlayerPw > 0 then
        return mCachedLivePlayerPw
    end
    return nil
end

-- Throttled from competitiveTrackFlow while staging UI is open; skipped if a reliable power request is in flight.
function M.requestStagingUiLivePowerRefresh()
    if pendingPowerCallback ~= nil then return end
    if not be or not be.getPlayerVehicleID or not be.getObjectByID then return end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return end
    local vehObj = be:getObjectByID(vehId)
    if not vehObj or not vehObj.queueLuaCommand then return end
    vehObj:queueLuaCommand(M._livePowerCacheScript)
end

-- Sync: may return nil if power cannot be read (e.g. no vehicle). Returns power in HP (same as filter/comparison).
function M.getPlayerVehiclePower()
    if not be or not be.getPlayerVehicleID then return nil end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return nil end
    if not core_vehicles or not core_vehicles.getVehicleDetails then return nil end
    local details = core_vehicles.getVehicleDetails(vehId)
    if not details then return nil end
    local configs = details.configs
    if not configs then return nil end
    return getPowerHpFromConfig(configs)
end

-- Sync curb weight (kg) from vehicle details config, or nil.
function M.getPlayerVehicleWeightKg()
    if not be or not be.getPlayerVehicleID then return nil end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId or not core_vehicles or not core_vehicles.getVehicleDetails then return nil end
    local details = core_vehicles.getVehicleDetails(vehId)
    if not details or not details.configs then return nil end
    return getWeightKgFromConfig(details.configs)
end

-- Returns player hp/kg and vehiclePool tier class when sync power+weight available.
function M.getPlayerVehiclePowerAndClass()
    if not be or not be.getPlayerVehicleID then return nil, nil end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId or not core_vehicles or not core_vehicles.getVehicleDetails then return nil, nil end
    local details = core_vehicles.getVehicleDetails(vehId)
    if not details or not details.configs then return nil, nil end
    local hp = getPowerHpFromConfig(details.configs)
    local wkg = getWeightKgFromConfig(details.configs)
    local pw = hpPerKgFromHpAndWeightKg(hp, wkg)
    if not pw then return nil, nil end
    return pw, getClassFromPwForVehiclePool(pw)
end

-- Called from vehicle Lua (queueGameEngineLua) or from UI (careerRequestPlayerPower response) with live power/weight.
-- Power may be HP-scale or watts; normalize to watts before callback (see liveMaxPowerRawToWatts).
function M.onPlayerVehiclePowerWeight(power, weight, gen)
    if gen ~= nil and gen ~= pendingPowerRequestGen then return end
    M._powerRequestUiFallbackTimer = nil
    pendingPowerRequestDeadline = nil
    local cb = pendingPowerCallback
    local vidForCache = pendingPowerVehId
    pendingPowerCallback = nil
    pendingPowerVehId = nil
    if type(cb) == "function" then
        local p = (type(power) == "number") and liveMaxPowerRawToWatts(power) or nil
        local w = (type(weight) == "number") and weight or nil
        if vidForCache and p and p > 0 and w and w > 0 then
            storeLivePowerSampleForVehicle(vidForCache, p, w)
        end
        cb(p, w)
    end
end

-- Vehicle calls this when engine not ready yet; we re-queue the script with retry+1 (Option B).
function M.onPlayerVehiclePowerWeightRetry(retryCount, gen)
    if gen ~= nil and gen ~= pendingPowerRequestGen then return end
    if type(pendingPowerCallback) ~= "function" or not pendingPowerVehId then return end
    if type(retryCount) ~= "number" or retryCount >= POWER_REQUEST_MAX_RETRIES then
        M.onPlayerVehiclePowerWeight(0, nil, pendingPowerRequestGen)
        return
    end
    local vehObj = be and be:getObjectByID(pendingPowerVehId)
    if vehObj and vehObj.queueLuaCommand then
        vehObj:queueLuaCommand(string.format(M._powerRequestScriptTemplate, retryCount + 1, POWER_REQUEST_MAX_RETRIES, pendingPowerRequestGen))
    else
        M.onPlayerVehiclePowerWeight(0, nil, pendingPowerRequestGen)
    end
end

local function beginPendingPowerRequest(callback, vehId)
    if type(pendingPowerCallback) == "function" then
        local oldCb = pendingPowerCallback
        pendingPowerCallback = nil
        pendingPowerVehId = nil
        pendingPowerRequestDeadline = nil
        M._powerRequestUiFallbackTimer = nil
        oldCb(nil, nil)
    end
    pendingPowerRequestGen = pendingPowerRequestGen + 1
    pendingPowerCallback = callback
    pendingPowerVehId = vehId
    pendingPowerRequestDeadline = os.clock() + POWER_REQUEST_DEADLINE_SEC
    return pendingPowerRequestGen
end

-- Request live power/weight. opts.preferLive: skip sync getVehicleDetails; use vehicle queueLuaCommand only (tuning-shop style, no UI activeObjectLua).
-- Default: Option A sync first, then Option C (UI) with vehicle fallback timer, else Option B vehicle-only.
function M.getPlayerVehiclePowerReliable(callback, opts)
    if type(callback) ~= "function" then return end
    if not be or not be.getPlayerVehicleID or not be.getObjectByID then
        callback(nil, nil)
        return
    end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then
        callback(nil, nil)
        return
    end

    local preferLive = type(opts) == "table" and opts.preferLive == true

    -- Option A: sync from vehicle details (fast but can be stale after parts/tuning until details refresh).
    if not preferLive then
        local powerHp = M.getPlayerVehiclePower()
        if type(powerHp) == "number" and powerHp > 0 then
            local details = core_vehicles and core_vehicles.getVehicleDetails and core_vehicles.getVehicleDetails(vehId)
            local weight = (details and details.configs and details.configs.total_weight) or (details and details.aggregates and details.aggregates.total_weight) or nil
            callback(powerHp * WATTS_PER_HP, weight)
            return
        end
    end

    -- Option C: UI activeObjectLua (skipped for preferLive — unreliable vs explicit vehObj:queueLuaCommand on player id).
    if not preferLive and guihooks and guihooks.trigger then
        beginPendingPowerRequest(callback, vehId)
        guihooks.trigger("careerRequestPlayerPower")
        M._powerRequestUiFallbackTimer = os.clock()
        return
    end

    local vehObj = be:getObjectByID(vehId)
    if not vehObj or not vehObj.queueLuaCommand then
        callback(nil, nil)
        return
    end
    local reqGen = beginPendingPowerRequest(callback, vehId)
    -- Option B: vehicle script retries until engine has maxPower or max retries (same vehicle via pendingPowerVehId).
    vehObj:queueLuaCommand(string.format(M._powerRequestScriptTemplate, 0, POWER_REQUEST_MAX_RETRIES, reqGen))
end

-- Sync eligibility: returns ok, msg. Fails open if power cannot be read.
function M.isPlayerEligibleForRace(race, businessXp)
    if not race then return true, nil end
    local cfg = getCurrentLevelConfig()
    local effectiveClass = getEffectiveClassFromXp(cfg, businessXp)
    local threshold = getEligibilityThresholdForClass(cfg, effectiveClass)
    if not threshold then return true, nil end
    local power = M.getPlayerVehiclePower()
    if power == nil then return true, nil end
    if power > threshold then
        return false, string.format("Vehicle exceeds Class %s limit (%d HP max for this race).", effectiveClass, threshold)
    end
    return true, nil
end

-- Async eligibility: requests reliable power from vehicle, then checks. Fails closed if power cannot be read.
function M.isPlayerEligibleForRaceAsync(race, businessXp, callback)
    if type(callback) ~= "function" then return end
    if not race then
        callback(true, nil)
        return
    end
    local cfg = getCurrentLevelConfig()
    local effectiveClass = getEffectiveClassFromXp(cfg, businessXp)
    local threshold = getEligibilityThresholdForClass(cfg, effectiveClass)
    if not threshold then
        callback(true, nil)
        return
    end
    M.getPlayerVehiclePowerReliable(function(powerWatts, weight)
        if powerWatts == nil then
            callback(false, "Vehicle power could not be read. Try again or use a different vehicle.")
            return
        end
        local powerHp = powerWattsToHp(powerWatts)
        if not powerHp or powerHp > threshold then
            callback(false, string.format("Vehicle exceeds Class %s limit (%d HP max for this race).", effectiveClass, threshold))
            return
        end
        callback(true, nil)
    end)
end

M.getMergedConfigForRace = getMergedConfigForRace

_G.career_modules_competitiveRace_aiRacers = M

return M
