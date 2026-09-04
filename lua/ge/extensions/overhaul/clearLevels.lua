local M = {}

local levelsRoot = 'levels/'

local function getSettings()
  return overhaul_settings.getSetting('mapDevMode')
end

local function normalizePath(p)
  return tostring(p or ''):gsub('\\', '/')
end

-- Resolve real userfolder root (handles current -> updating junctions).
local function getResolvedUserRoot()
  if type(FS.getFileRealPath) == 'function' then
    local settingsReal = normalizePath(FS:getFileRealPath('settings'))
    if settingsReal ~= '' then
      local idx = settingsReal:find('/settings/?$') or settingsReal:find('/settings/')
      if idx then
        return settingsReal:sub(1, idx)
      end
    end
  end
  local user = normalizePath(FS:getUserPath())
  if user ~= '' and not string.endswith(user, '/') then
    user = user .. '/'
  end
  return user
end

-- Only files on disk under <userfolder>/levels/<map>/... (not mods/ or game mounts).
local function isUserLevelsOverlayFile(vpath, map)
  if type(FS.getFileRealPath) ~= 'function' then
    return false
  end
  local real = normalizePath(FS:getFileRealPath(vpath))
  if real == '' then
    return false
  end
  if real:find('/mods/') then
    return false
  end
  local userRoot = getResolvedUserRoot()
  if userRoot == '' then
    return false
  end
  local mapPrefix = userRoot .. 'levels/' .. map .. '/'
  return string.startswith(real, mapPrefix)
end

local function backupMapOverlay(map)
  local srcRoot = levelsRoot .. map
  local dstRoot = levelsRoot .. map .. '_backup'

  -- Keep an existing sidecar backup so later stub recreates don't overwrite WE work.
  if FS:directoryExists(dstRoot) then
    local existing = FS:findFiles(dstRoot, '*.*', -1, true, false) or {}
    if #existing > 0 then
      log('I', 'clearLevels', string.format('[%s] keeping existing backup at %s (%d file(s))', map, dstRoot, #existing))
      return true, 0, true
    end
  end

  local files = FS:findFiles(srcRoot, '*.*', -1, true, false) or {}
  local userFiles = {}

  for _, vpath in ipairs(files) do
    vpath = normalizePath(vpath):gsub('^/', '')
    if isUserLevelsOverlayFile(vpath, map) then
      table.insert(userFiles, vpath)
    end
  end

  if #userFiles == 0 then
    log('I', 'clearLevels', string.format('[%s] no userfolder overlay files to backup', map))
    return true, 0, false
  end

  if FS:directoryExists(dstRoot) then
    FS:directoryRemove(dstRoot)
  end
  FS:directoryCreate(dstRoot, true)

  local copied = 0
  local failed = 0
  local prefix = srcRoot .. '/'
  for _, vpath in ipairs(userFiles) do
    local rel = vpath
    if string.startswith(rel, prefix) then
      rel = rel:sub(#prefix + 1)
    elseif string.startswith(rel, srcRoot) then
      rel = rel:sub(#srcRoot + 1):gsub('^/', '')
    end
    local dest = dstRoot .. '/' .. rel
    local parent = dest:match('(.+)/[^/]+$')
    if parent and not FS:directoryExists(parent) then
      FS:directoryCreate(parent, true)
    end
    local ok = FS:copyFile(vpath, dest)
    if ok == 0 then
      copied = copied + 1
    else
      failed = failed + 1
      log('E', 'clearLevels', string.format('[%s] copy failed: %s -> %s (code %s)', map, vpath, dest, tostring(ok)))
    end
  end

  log('I', 'clearLevels', string.format('[%s] backup %d file(s) to %s (%d failed)', map, copied, dstRoot, failed))
  return failed == 0 and copied == #userFiles, copied, false
end

local function clearLevels()
  if getSettings() then
    log('I', 'clearLevels', 'mapDevMode on, skipping')
    return
  end

  log('I', 'clearLevels', 'backup-then-delete → levels/<map>_backup')

  if not FS:directoryExists(levelsRoot) then
    log('I', 'clearLevels', 'levels/ missing, nothing to do')
    return
  end

  local maps = overhaul_maps.getCompatibleMaps()
  for map, _ in pairs(maps) do
    if not map:find('_backup$') then
      local path = levelsRoot .. map
      if FS:directoryExists(path) then
        local ok, copied, keptExisting = backupMapOverlay(map)
        if not ok then
          log('W', 'clearLevels', string.format('[%s] backup did not succeed; skipping delete', map))
        else
          if keptExisting then
            log('I', 'clearLevels', string.format('[%s] directoryRemove %s (prior _backup kept)', map, path))
          elseif copied > 0 then
            log('I', 'clearLevels', string.format('[%s] backup ok (%d files), directoryRemove %s', map, copied, path))
          else
            log('I', 'clearLevels', string.format('[%s] no overlay to backup, directoryRemove %s', map, path))
          end
          FS:directoryRemove(path)
        end
      else
        log('I', 'clearLevels', string.format('[%s] vfs path missing, skip', map))
      end
    end
  end

  log('I', 'clearLevels', 'done — live levels/<map> cleared; backup at levels/<map>_backup')
end

M.changeDevMode = function(devMode)
end

M.onExtensionLoaded = clearLevels
M.clearLevels = clearLevels

return M
