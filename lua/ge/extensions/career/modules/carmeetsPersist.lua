-- Car meet save/load persistence. Plain require module (not an extension) so
-- carmeets.lua stays under Lua's 200-local limit per chunk.

local M = {}

M.SAVE_FILE = "carmeets.json"
M.RELATIVE_DIR = "career/rls_career"
M.MIN_REPUTATION = 0
M.MAX_REPUTATION = 100

local ctx = nil

function M.bind(bindCtx)
  ctx = bindCtx
end

local function clampReputation(value)
  return math.min(M.MAX_REPUTATION, math.max(M.MIN_REPUTATION, value or 0))
end

local function getDirPath(savePath)
  return savePath .. "/" .. M.RELATIVE_DIR
end

local function ensureDir(savePath)
  local dirPath = getDirPath(savePath)
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  return dirPath
end

local function buildPayload(state)
  return {
    lastGenerationTime = state.lastGenerationTime,
    rsvpData = state.rsvpData,
    pendingInvites = state.pendingInvites,
    playerMeetReputation = state.playerMeetReputation,
    nextInviteId = state.nextInviteId,
    joinedClubs = state.joinedClubs,
    attendanceHistory = state.attendanceHistory,
  }
end

local function writeToPath(savePath, state)
  if not savePath then
    return false
  end
  ensureDir(savePath)
  career_saveSystem.jsonWriteFileSafe(getDirPath(savePath) .. "/" .. M.SAVE_FILE, buildPayload(state), true)
  return true
end

function M.reset()
  if not ctx then
    return
  end
  ctx.setState({
    lastGenerationTime = 0,
    rsvpData = nil,
    pendingInvites = {},
    playerMeetReputation = 0,
    nextInviteId = 1,
    joinedClubs = {},
    attendanceHistory = {},
    loadedSavePath = nil,
    sceneRepDirty = false,
  })
end

function M.persist()
  if not ctx then
    return false
  end
  if not ctx.isCareerActive() then
    return false
  end
  local activeSavePath = ctx.getActiveSavePath()
  if not activeSavePath then
    return false
  end
  local state = ctx.read()
  if state.loadedSavePath and state.loadedSavePath ~= activeSavePath then
    return false
  end
  if writeToPath(activeSavePath, state) then
    state.loadedSavePath = activeSavePath
    state.sceneRepDirty = false
    ctx.setState(state)
    return true
  end
  return false
end

function M.load(currentSavePath, forceReload)
  if not ctx then
    return
  end
  if not currentSavePath and not ctx.isCareerActive() then
    return
  end
  if not currentSavePath then
    currentSavePath = ctx.getActiveSavePath()
  end
  if not currentSavePath then
    return
  end

  local state = ctx.read()
  local sameProfile = state.loadedSavePath == currentSavePath
  if not forceReload then
    if sameProfile and state.sceneRepDirty then
      return
    end
    if sameProfile then
      return
    end
  end

  local filePath = getDirPath(currentSavePath) .. "/" .. M.SAVE_FILE
  local data = jsonReadFile(filePath)
  if data then
    ctx.setState({
      lastGenerationTime = data.lastGenerationTime or 0,
      rsvpData = data.rsvpData,
      pendingInvites = data.pendingInvites or {},
      playerMeetReputation = clampReputation(data.playerMeetReputation or data.reputation or 0),
      nextInviteId = data.nextInviteId or (#(data.pendingInvites or {}) + 1),
      joinedClubs = data.joinedClubs or {},
      attendanceHistory = data.attendanceHistory or {},
      loadedSavePath = currentSavePath,
      sceneRepDirty = false,
    })
  else
    ctx.setState({
      lastGenerationTime = 0,
      rsvpData = nil,
      pendingInvites = {},
      playerMeetReputation = 0,
      nextInviteId = 1,
      joinedClubs = {},
      attendanceHistory = {},
      loadedSavePath = currentSavePath,
      sceneRepDirty = false,
    })
  end
end

local function normalizeSavePath(p)
  return tostring(p or ""):gsub("\\", "/"):gsub("/+$", "")
end

local function saveFamily(path)
  path = normalizeSavePath(path)
  return path:match("^(.*)/[^/]+$") or path
end

local function sameSaveFamily(a, b)
  if not a or not b then
    return false
  end
  return saveFamily(a) == saveFamily(b)
end

function M.onSaveCurrentProfile(currentSavePath)
  if not ctx or not currentSavePath then
    return
  end

  local activeSavePath = ctx.getActiveSavePath()
  if not activeSavePath then
    return
  end

  local state = ctx.read()
  local livePath = state.loadedSavePath or activeSavePath
  if not sameSaveFamily(livePath, currentSavePath) and not sameSaveFamily(activeSavePath, currentSavePath) then
    return
  end

  writeToPath(currentSavePath, state)
  state.loadedSavePath = currentSavePath
  state.sceneRepDirty = false
  ctx.setState(state)
end

return M
