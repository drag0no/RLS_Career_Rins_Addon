<template>
  <div class="app-uiapps-overlay-wrapper" v-show="!splitActive">
    <UiAppsOverlay class="app-uiapps-overlay" />
  </div>

  <SplitScreenHud />

  <PhotomodeOverlay v-if="isPhotomodeRoute" class="app-photomode-overlay" />

  <MainBackground ref="mainBackground" v-if="bgRequired" :transition="20" />

  <div
    v-if="isPhotomodeRoute"
    id="photomode-composition-grid-host"
    class="app-photomode-composition-grid-host"
  />

  <Teleport :to="legacyAngularHostTarget" :disabled="!legacyAngularHostTarget">
    <AngularHost
      :click-through="angularHostClickThrough"
      :ui-nav-enabled="legacyAngularHostUiNavEnabled"
      :show-back-button="showLegacyAngularMenuBackButton"
      @back="onLegacyAngularBack"
    />
  </Teleport>

  <VehicleTriggerCrosshair />

  <div class="vue-app-main" v-bng-ui-nav="baseUiNavEnabled">
    <router-view v-if="route.name !== '__legacyAngular'" />
    <div v-if="!hasLayoutSingle && !splitActive" class="app-infobar-wrapper">
      <InfoBar class="app-infobar" />
    </div>
  </div>

  <div v-if="!isPauseView && !$simplemenu" class="app-pause-button-host">
    <PauseButton inline />
  </div>

  <div
    v-if="sfcLoadingVisible"
    class="app-sfc-loading-block"
    @mousedown.capture="onSfcLoadingMouseDown"
    @click="onSfcLoadingClick"
  />

  <Popup type="activity" v-if="route.name === 'play'" />
  <ToastHost />
  <Popup>
    <Popover />
    <IExplorer v-if="showIExplorer" />
    <div v-if="reloadNeeded" class="app-reload-needed">UI reload is needed, press F5</div>
  </Popup>

  <LoadingScreen />

  <RacingTeamProxyOverlay />
  <RacingTeamProxyTeamLoading />
  <RlsCareerLoadingOverlay />
  <RacingTeamMilestoneSplash />
  <SceneToastOverlay />
  <TravelJournalScenePrompt />
  <PhoneLockNotificationOverlay />
  <PhoneTutorialOverlay />

  <Splashscreen v-if="showSplashscreen" class="app-splashscreen" @done="onSplashscreenDone" />

  <ModStyles />
</template>

<script setup>
import { ref, computed, watch, provide, inject, onUnmounted } from "vue"
import { useRoute } from "vue-router"
import { SysInfo } from "@/services"
import { LAYOUT_ALIGNMENTS } from "@/common/layouts"
import LoadingScreen from "@/common/modules/loading/views/LoadingScreen.vue"
import PauseButton from "@/common/modules/pause/components/pauseButton.vue"
import PhotomodeOverlay from "@/modules/pause/views/photomode/components/PhotomodeOverlay.vue"
import UiAppsOverlay from "@/modules/apps/views/UiAppsOverlay.vue"
import SplitScreenHud from "@/modules/splitscreen/SplitScreenHud.vue"
import { photomodeEditing } from "@/modules/pause/views/photomode/useOverlays"
import IExplorer from "@/modules/debug/components/IExplorer.vue"
import InfoBar from "@/common/modules/infobar/components/InfoBar.vue"
import Popup from "@/common/modules/popup/views/Popup.vue"
import ToastHost from "@/common/modules/toast/views/ToastHost.vue"
import Popover from "@/common/views/Popover.vue"
import VehicleTriggerCrosshair from "@/common/components/utility/VehicleTriggerCrosshair.vue"
import MainBackground from "@/common/modules/main-bg/components/MainBackground.vue"
import AngularHost from "@/modules/legacyAngularHost/components/AngularHost.vue"
import { ModStyles } from "@/common/components/utility"
import { useSettings } from "@/services/settings"
import { lua, useBridge } from "@/bridge"
import { useRouteDataStore } from "@/services/routeData"
import { getRouteScopeValidatorInstance } from "@/services/scopedNav"
import Splashscreen from "@/common/modules/splashScreen/Splashscreen.vue"
import { vBngUiNav } from "@/common/directives"
import { useRuntimeLoadingOverlay } from "@/services/useRuntimeLoadingOverlay"
import router from "@/router"
import RacingTeamProxyOverlay from "@/modules/career/components/RacingTeamProxyOverlay.vue"
import RacingTeamProxyTeamLoading from "@/modules/career/components/RacingTeamProxyTeamLoading.vue"
import RlsCareerLoadingOverlay from "@/modules/career/components/RlsCareerLoadingOverlay.vue"
import RacingTeamMilestoneSplash from "@/modules/career/components/RacingTeamMilestoneSplash.vue"
import SceneToastOverlay from "@/modules/career/components/SceneToastOverlay.vue"
import TravelJournalScenePrompt from "@/modules/career/components/TravelJournalScenePrompt.vue"
import PhoneLockNotificationOverlay from "@/modules/career/components/PhoneLockNotificationOverlay.vue"
import PhoneTutorialOverlay from "@/modules/career/components/PhoneTutorialOverlay.vue"

const route = useRoute()

const {
  visible: sfcLoadingVisible,
  onOverlayMouseDown: onSfcLoadingMouseDown,
  onOverlayClick: onSfcLoadingClick,
} = useRuntimeLoadingOverlay()
const baseUiNavEnabled = computed(() => route.name !== "__legacyAngular" && route.meta?.uiNav !== false)
const routeDataStore = useRouteDataStore()
const globalStore = inject("$globalStore", window.vueGlobalStore || {})
const isPauseView = computed(() => {
  const canonicalRouteName = String(routeDataStore.routeName || "")
  const fallbackRouteName = canonicalRouteName || String(route.name || "")
  return fallbackRouteName === "pause" || fallbackRouteName.startsWith("pause.")
})
const isPhotomodeRoute = computed(() => /(^|\.)(pause|garage)\.photomode(\.|$)/.test(route.name || ""))
const photomodeSoloEdit = computed(() => isPhotomodeRoute.value && photomodeEditing.value)
watch(photomodeSoloEdit, solo => {
  document.body.classList.toggle("photomode-solo-edit", solo === true)
}, { immediate: true })

const settings = useSettings()

const { events, api } = useBridge()

const $simplemenu = inject("$simplemenu")

const bngVue = window.bngVue || {}

const uiScaleBasePx = 16
const uiScaleDefault = 1
const uiScaleLimits = [0.5, 2.0]

function normalizeUiScale(value) {
  const parsedValue = Number(value)
  const safeValue = Number.isFinite(parsedValue) ? parsedValue : uiScaleDefault
  return Math.max(uiScaleLimits[0], Math.min(uiScaleLimits[1], safeValue))
}

function setScale(value) {
  const scale = normalizeUiScale(value)
  const rootStyle = document.documentElement.style
  const bodyStyle = document.body.style
  window.requestAnimationFrame(() => {
    rootStyle.setProperty("--ui-scale", String(scale))
    rootStyle.setProperty("font-size", `${uiScaleBasePx * scale}px`)
    bodyStyle.setProperty("font-size", "inherit")
  })
}

watch(() => settings.values.uiContentScale, setScale, { immediate: true })

events.on("onCefVisibilityChanged", visible => {
  document.body.classList.toggle("ui-hidden", !visible)
})

const showIExplorer = ref(!!window._VueDebugState)
bngVue.debug = (state = true) => {
  window._VueDebugState = !!state
  showIExplorer.value = !!state
  return showIExplorer.value
}
events.on("onCEFDevToolsVisibility", bngVue.debug)

const reloadNeeded = ref(!!window.bngRuntime?.reloadNeeded)
events.on("UiRuntimeReloadNeeded", () => { reloadNeeded.value = true })

const splitActive = ref(false)
events.on("splitScreenPlayers", n => { splitActive.value = (Number(n) || 0) > 0 })

const legacyAngularHostTarget = ref(null)
provide("angularHostTargetRef", legacyAngularHostTarget)

const angularClickThroughStates = new Set(["", "blank", "play"])
const angularRouteName = ref("")
events.on("AngularStateChanged", data => {
  angularRouteName.value = String(data?.name || "")
})
const angularHostClickThrough = computed(() =>
  angularClickThroughStates.has(angularRouteName.value) && globalStore.__introPopupShown !== true
)
const legacyAngularHostUiNavEnabled = computed(() =>
  route.name === "__legacyAngular" && !angularHostClickThrough.value
)
const showLegacyAngularMenuBackButton = computed(() =>
  route.name === "__legacyAngular" && routeDataStore.breadcrumbs.length > 1
)

function onLegacyAngularBack() {
  lua.extensions.ui_router.back()
}

bngVue.gotoAngularState = async (state = "blank", params = undefined) => await bngVue.gotoGameState(state, { params })

bngVue.gotoGameState = async (state = "ui-test", { params = false } = {}) => {
  await lua.extensions.ui_router.navigate(state, params, null)
}

bngVue.gotoGameStateOriginal = (
  state = "ui-test",
  { params = false, tryAngularJS = true, blankAngularJS = true, clickThrough = false } = {}
) => {
  const a = history.state
  void clickThrough
  if (!router.hasRoute(state)) {
    window.location.hash = "#/" + state
    if (tryAngularJS) bngVue.gotoAngularState(state, params)
  } else {
    blankAngularJS && bngVue.gotoAngularState("blank")
    const newroute = router.resolve({ name: state, params })
    window.location.hash = newroute.href
    router.replace({ name: state, params })
  }
  history.replaceState(a, "", window.location.toString())
}

bngVue.getCurrentRoute = () => router.currentRoute.value

const layoutSingleCount = ref(0)
const hasLayoutSingle = computed(() => layoutSingleCount.value > 0)
const showSplashscreen = ref(true)

function onSplashscreenDone() {
  showSplashscreen.value = false
}

provide("layoutSinglePresence", {
  register() {
    layoutSingleCount.value++
  },
  unregister() {
    layoutSingleCount.value = Math.max(0, layoutSingleCount.value - 1)
  },
})

const mainBgPausedRoutes = ["menu.extras.credits"]
const bgRequired = SysInfo.mainMenuBackgroundRequired
const mainBackground = ref()
provide("mainBackground", computed(() => mainBackground.value?.carousel))
provide("mainBackgroundBlur", computed(() => mainBackground.value?.backgrounds.blur))

watch([
  () => route.name,
  () => mainBackground.value,
], () => {
  const carousel = mainBackground.value?.carousel
  if (!carousel) return
  if (mainBgPausedRoutes.includes(route.name)) {
    carousel.pause?.()
  } else {
    carousel.play?.()
  }
}, { immediate: true })

watch([
  () => settings.values.uiLayoutContentAlignment,
  () => settings.values.uiLayoutContentWidth,
], ([alignment, width]) => {
  const rootStyle = document.documentElement.style
  alignment = LAYOUT_ALIGNMENTS[alignment || "center"]
  width = width ? `${width}px` : "100vw"
  window.requestAnimationFrame(() => {
    rootStyle.setProperty("--layout-content-alignment", alignment)
    rootStyle.setProperty("--layout-content-width", width)
  })
}, { immediate: true })

const updateSafezones = () => {
  const limit = { min: 0.8, max: 1, default: 0.98 }
  const apply = safeArea => {
    safeArea = Number(safeArea)
    if (isFinite(safeArea)) {
      safeArea = Math.max(limit.min, Math.min(limit.max, safeArea))
    } else {
      safeArea = limit.default
    }
    if (safeArea === 1 && $simplemenu.value) {
      safeArea = limit.default
    }
    let w = window.innerWidth, h = window.innerHeight
    if (h > w) [w, h] = [h, w]
    if (w / h > 16 / 9) w = h * (16 / 9)
    const pad = Math.round(w * (1 - safeArea) / 2)
    const rootStyle = document.documentElement.style
    window.requestAnimationFrame(() => {
      rootStyle.setProperty("--safezone", `${pad}px`)
    })
  }
  const area = settings.values.uiLayoutSafeArea
  if ($simplemenu.value || !area) {
    api.engineLua("Engine.UI.safeAreaNormalized()", apply)
  } else {
    apply(area)
  }
}

window.addEventListener("resize", updateSafezones)
onUnmounted(() => window.removeEventListener("resize", updateSafezones))
watch(() => settings.values.uiLayoutSafeArea, updateSafezones, { immediate: true })

events.on("ui_router_routeData", payload => {
  routeDataStore.setRouteData(payload)
  getRouteScopeValidatorInstance()?.onRouteData(payload)
})
</script>

<style scoped lang="scss" src="@/styles/main.scss" />

<style lang="scss">
.vue-app-main {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  width: 100%;
  height: 100%;
  z-index: var(--zorder_index_fullscreen_default);
  display: flex;
  flex-direction: column;
  align-items: stretch;
  font-family: var(--fnt-defs);
  overflow: hidden;
  pointer-events: none;
  > * {
    pointer-events: all;
  }
}

.screen-locked {
  &, * {
    pointer-events: none !important;
  }
}

.app-pause-button-host {
  position: absolute;
  top: 0;
  right: 0;
  height: 2.5em;
  z-index: var(--zorder_index_waiting_screen_icon);
  display: inline-flex;
  align-items: stretch;
  pointer-events: auto;
}

.app-pause-button-host .pause-button {
  --bng-button-min-width: 2em;
  --bng-button-custom-margin: 0;
  --bng-button-custom-enabled: var(--bng-ter-blue-gray-600);
  --bng-button-custom-hover: var(--bng-ter-blue-gray-550);
  --bng-button-custom-active: var(--bng-ter-blue-gray-800);
  --bng-button-custom-disabled: var(--bng-cool-gray-800);
  --bng-button-custom-enabled-opacity: 0.8;
  --bng-button-custom-hover-opacity: 1;
  --bng-button-custom-active-opacity: 1;
  --bng-button-custom-disabled-opacity: 0.25;
  --bng-button-custom-border-radius: 0;
  align-self: stretch;
  align-items: center;
  gap: 0.25em;
}

.app-photomode-overlay {
  position: fixed;
  inset: 0;
  pointer-events: none;
}

.app-photomode-composition-grid-host {
  position: fixed;
  inset: 0;
  pointer-events: none;
}

.app-uiapps-overlay-wrapper {
  position: fixed;
  inset: 0;
  pointer-events: none;
  display: flex;
  flex-direction: column;
  align-items: var(--layout-content-alignment);
  padding: var(--safezone);
  box-sizing: border-box;
}

.app-infobar-wrapper {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: var(--safezone);
  pointer-events: none;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;

  .app-infobar.info-bar {
    position: relative;
    bottom: unset;
  }
}

.app-uiapps-overlay {
  position: relative;
  width: 100%;
  max-width: max(33.4%, var(--layout-content-width));
  height: 100%;
  flex: 1 1 auto;
}

.app-splashscreen {
  z-index: 2147483646;
}

.app-sfc-loading-block {
  position: fixed;
  inset: 0;
  z-index: 14000;
  background: transparent;
  pointer-events: all;
}

.app-reload-needed {
  position: fixed;
  top: 0;
  left: 0;
  z-index: 2147483647;
  padding: 0.3em 0.6em;
  background: rgba(0, 0, 0, 0.85);
  color: var(--bng-add-red-300, #ff5a5a);
  font-family: var(--fnt-mono, monospace);
  font-weight: 700;
  pointer-events: none;
}

body.photomode-solo-edit {
  .app-photomode-overlay {
    z-index: 11000;
    pointer-events: auto;
  }

  .vue-app-main,
  .app-uiapps-overlay-wrapper {
    display: none !important;
  }
}
</style>

<style lang="scss">
@use '@/modules/career/styles/career-device-scrollbars';
</style>
