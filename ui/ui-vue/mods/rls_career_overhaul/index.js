/**
 * Mount career overlay components that used to live in mod App.vue.
 * BeamNG 0.39 serves the Vue shell from ui-vue/dist, so VFS App.vue overrides
 * do not run. Official mod entry points under ui/ui-vue/mods/ do.
 *
 * Overlays call useRoute()/useRouter(), so they must share the main app context
 * (cannot be a second createApp with the same router instance).
 */
import { getComponent } from "@/services/modManager"

const OVERLAY_FILE = "/ui/ui-vue/mods/rls_career_overhaul/RlsCareerOverlays.vue"
const HOST_ID = "rls-career-overlays-host"
const CROSSFIRE_NO_BUTTON_MSG = "Couldn't locate any button anywhere. Menu navigation won't work"

let hostEl = null
let originalConsoleLog = null

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/** Mute vanilla crossfire spam when UI-nav fires with no focusable controls (e.g. FRE + console). */
function silenceCrossfireNavSpam() {
  if (originalConsoleLog) return
  originalConsoleLog = console.log.bind(console)
  console.log = (...args) => {
    if (args[0] === CROSSFIRE_NO_BUTTON_MSG) return
    return originalConsoleLog(...args)
  }
}

function restoreConsoleLog() {
  if (!originalConsoleLog) return
  console.log = originalConsoleLog
  originalConsoleLog = null
}

async function waitForMainApp(timeoutMs = 60000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (window.Vue && window.bngVue?.app?._context && window.vueRouter) {
      return true
    }
    await sleep(50)
  }
  return false
}

function unmountHost() {
  if (hostEl && window.Vue?.render) {
    try {
      window.Vue.render(null, hostEl)
    } catch (_) {
      // ignore
    }
  }
  if (hostEl) {
    hostEl.remove()
    hostEl = null
  }
}

async function mountOverlays() {
  const ready = await waitForMainApp()
  if (!ready) {
    console.error("[rls_career_overhaul] Timed out waiting for Vue app context")
    return false
  }

  let data = await getComponent(OVERLAY_FILE, false, true)
  if (!data?.compiled && typeof data?.compile === "function") {
    data = await data.compile()
  }
  if (data?.error) {
    console.error("[rls_career_overhaul] Overlay compile failed", data.error, data.errorObj)
    return false
  }
  if (!data?.component) {
    console.error("[rls_career_overhaul] Overlay component missing after compile")
    return false
  }

  unmountHost()

  hostEl = document.createElement("div")
  hostEl.id = HOST_ID
  document.body.appendChild(hostEl)

  const vnode = window.Vue.createVNode(data.component)
  vnode.appContext = window.bngVue.app._context
  window.Vue.render(vnode, hostEl)
  console.log("[rls_career_overhaul] Career overlays mounted")
  return true
}

export async function onLoad() {
  silenceCrossfireNavSpam()
  try {
    await mountOverlays()
  } catch (err) {
    console.error("[rls_career_overhaul] Failed to mount career overlays", err)
  }
}

export async function onUnload() {
  unmountHost()
  restoreConsoleLog()
}
