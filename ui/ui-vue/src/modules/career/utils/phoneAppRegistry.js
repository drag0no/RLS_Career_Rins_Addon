import { ref } from 'vue'
import {
  DEFAULT_DOCK_APP_IDS,
  PREINSTALLED_APP_IDS,
  SYSTEM_APP_IDS,
} from './phoneLayoutUtils'
import { APP_MANIFESTS } from '../apps/manifests/index.js'

// Add a new app by creating `ui/ui-vue/src/modules/career/apps/manifests/<app-id>.js`
// and exporting a default manifest object.
function isValidManifest(manifest) {
  return !!(manifest && manifest.id && manifest.name && manifest.route && (manifest.icon || manifest.iconImage || manifest.iconTile))
}

function compareAppNames(a, b) {
  return String(a?.name || '').localeCompare(String(b?.name || ''), undefined, { sensitivity: 'base' })
}

function sortAppsByName(apps) {
  return [...(apps || [])].sort(compareAppNames)
}

function loadAppDefinitions() {
  const manifests = APP_MANIFESTS.filter(isValidManifest)

  manifests.sort((a, b) => {
    const pageA = Number.isFinite(a.defaultPage) ? a.defaultPage : 999
    const pageB = Number.isFinite(b.defaultPage) ? b.defaultPage : 999
    if (pageA !== pageB) return pageA - pageB

    const posA = Number.isFinite(a.defaultPosition) ? a.defaultPosition : 999
    const posB = Number.isFinite(b.defaultPosition) ? b.defaultPosition : 999
    if (posA !== posB) return posA - posB

    return compareAppNames(a, b)
  })

  return manifests
}

function normalizeImagePathForBeamNG(path) {
  if (typeof path !== 'string') return path
  if (path.startsWith('/local/ui/ui-vue/')) {
    return path.slice('/local/ui/ui-vue/'.length)
  }
  return path
}

function resolveManifestIconImage(def) {
  const raw = def.iconTile || def.iconImage
  if (typeof raw !== 'string') return raw

  const normalized = normalizeImagePathForBeamNG(raw)
  const hasScheme = /^(?:[a-z]+:)?\/\//i.test(normalized)
  const isDataUri = normalized.startsWith('data:')
  const isAbsoluteLike = normalized.startsWith('/') || normalized.startsWith('./') || normalized.startsWith('../')
  const alreadyTiled = normalized.startsWith('tiles/')

  if (hasScheme || isDataUri || isAbsoluteLike || alreadyTiled) {
    return normalized
  }
  return `/ui/entrypoints/main/tiles/${normalized}`
}

function enrichApp(def) {
  return {
    ...def,
    iconImage: resolveManifestIconImage(def),
    systemApp: def.systemApp === true || SYSTEM_APP_IDS.has(def.id),
    hideFromStore: def.hideFromStore === true || SYSTEM_APP_IDS.has(def.id),
  }
}

const APP_DEFINITIONS = loadAppDefinitions().map(enrichApp)

const APPS_PER_PAGE = 16
const GRID_COLS = 4
const GRID_ROWS = 4

const DEFAULT_DOCK_IDS = (() => {
  const dock = new Array(4).fill(null)
  for (const app of APP_DEFINITIONS) {
    if (!Number.isInteger(app.defaultDock)) continue
    if (app.defaultDock < 0 || app.defaultDock >= 4) continue
    if (!dock[app.defaultDock]) dock[app.defaultDock] = app.id
  }
  return dock.map((id, idx) => id || DEFAULT_DOCK_APP_IDS[idx] || null)
})()

const catalogApps = ref([])
const availableApps = ref([])

export const DEFAULT_SKILL_LOCKED_MESSAGE = 'Unlock skill to use this app'

async function isCareerActive(luaBridge) {
  try {
    await luaBridge.extensions.load('ui_phone_layout')
    const fromLayout = await luaBridge.ui_phone_layout.getCareerActive()
    if (fromLayout) return true
  } catch { /* layout optional */ }
  try {
    return !!(await luaBridge.career_career.isActive())
  } catch {
    return false
  }
}

async function passesUnlock(def, luaBridge) {
  if (!def.unlockCondition) return true
  try {
    return !!(await def.unlockCondition(luaBridge))
  } catch (err) {
    console.warn(`[phoneAppRegistry] unlockCondition failed for '${def.id}'`, err)
    return false
  }
}

function catalogEntry(def, isUsageUnlocked) {
  const enriched = enrichApp(def)
  const storeTagline = typeof def.storeTagline === 'string' && def.storeTagline.trim()
    ? def.storeTagline.trim()
    : (def.category || '')
  const storeDescription = typeof def.storeDescription === 'string' && def.storeDescription.trim()
    ? def.storeDescription.trim()
    : `Install ${def.name} on your home screen for quick access during your career.`
  return {
    ...enriched,
    storeTagline,
    storeDescription,
    isUsageUnlocked,
    lockedMessage: typeof def.lockedMessage === 'string' && def.lockedMessage
      ? def.lockedMessage
      : DEFAULT_SKILL_LOCKED_MESSAGE,
  }
}

export function usePhoneApps() {
  async function refreshApps(luaBridge) {
    const catalog = []
    const careerActive = await isCareerActive(luaBridge)
    for (const def of APP_DEFINITIONS) {
      if (!def.unlockCondition) {
        catalog.push(catalogEntry(def, true))
        continue
      }
      const unlocked = await passesUnlock(def, luaBridge)
      if (unlocked) {
        catalog.push(catalogEntry(def, true))
        continue
      }
      // Skill-gated apps: visible in the store during career even before the skill unlocks.
      if (def.showInStoreWhenLocked && careerActive) {
        catalog.push(catalogEntry(def, false))
      }
    }
    catalogApps.value = sortAppsByName(catalog)
    availableApps.value = catalogApps.value
  }

  async function refreshCatalogApps(luaBridge) {
    await refreshApps(luaBridge)
    return catalogApps.value
  }

  function setInstalledApps(installedIds) {
    const installed = new Set(installedIds || [])
    PREINSTALLED_APP_IDS.forEach(id => installed.add(id))
    const catalogById = new Map(catalogApps.value.map(app => [app.id, app]))
    const out = []
    for (const id of installed) {
      if (catalogById.has(id)) {
        out.push(catalogById.get(id))
        continue
      }
      const def = APP_DEFINITIONS.find(app => app.id === id)
      if (def) out.push(catalogEntry(def, false))
    }
    availableApps.value = sortAppsByName(out)
  }

  async function isAppUsageUnlocked(appId, luaBridge) {
    const def = APP_DEFINITIONS.find(app => app.id === appId)
    if (!def) return true
    return passesUnlock(def, luaBridge)
  }

  function getStoreApps() {
    return sortAppsByName(catalogApps.value.filter(app => !app.hideFromStore))
  }

  return {
    availableApps,
    catalogApps,
    refreshApps,
    refreshCatalogApps,
    setInstalledApps,
    getStoreApps,
    isAppUsageUnlocked,
    APP_DEFINITIONS,
    DEFAULT_SKILL_LOCKED_MESSAGE,
    APPS_PER_PAGE,
    GRID_COLS,
    GRID_ROWS,
    DEFAULT_DOCK_IDS,
    PREINSTALLED_APP_IDS,
    SYSTEM_APP_IDS,
  }
}
