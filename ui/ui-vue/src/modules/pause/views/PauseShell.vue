<template>
  <LayoutMenu
    class="pause-layout"
    nav-scope="pause-root"
    :nav-active="false"
    :nav-auto-focus="layoutNavAutoFocus"
    :nav-options="pauseRootNavOptions"
    main-card-autofocus
    :show-card1="showMainCard"
    :show-card2="hasSecondCard"
    :show-buttons-left="pauseRailHasActions"
    :main-card-class="mainCardClass"
    :side-card-class="sideCardClass"
    :main-card-bubble-whitelist-events="PAUSE_BUBBLE_EVENTS"
    :main-card-can-ignore-event="onMainCardNavEvent"
    :tabs="menuTabs"
    :breadcrumbs="breadcrumbItems"
    v-model:selectedTab="selectedTabIndex"
    :heading="pauseHeadingText"
    v-bng-ui-nav-label:tab_l="tabLeftHintLabel"
    v-bng-ui-nav-label:tab_r="tabRightHintLabel"
    @before-navigate="onBeforeNavigate"
    @tab-change="onTabChange"
    @breadcrumb-click="onBreadcrumbClick"
    @breadcrumb-back="onBreadBack"
  >
    <template #topbar-right>
      <div class="system-info">
        <Background />
        <PauseButton inline />
        <div class="system-time">{{ currentTime }}</div>
        <BngServiceProvidersUser
          class="username"
          v-bng-blur
          :service-providers="SysInfo.serviceProviders.value"
          :service-providers-online="SysInfo.serviceProvidersOnline.value"
        />
      </div>
    </template>

    <template #card1>

      <div v-if="activeModTab" class="pause-main-card">
        <component
          v-if="activeModCard1"
          :key="`${modManager.refreshToken}:${activeModCard1.componentName}`"
          :is="activeModCard1.component"
          v-bind="activeModCard1.props"
          class="pause-content-component"
        />
      </div>
      <div v-else class="pause-main-card">
        <div
          v-for="element in mainPanelResolvedContent"
          :key="element.key"
          class="pause-content-item"
        >
          <BngCardHeading v-if="element.type === 'title'" type="ribbon">
            {{ $tt(element.text || element.title || element.id) }}
          </BngCardHeading>
          <div v-else-if="element.type === 'text'" class="pause-content-text">
            {{ $tt(element.text || element.description || "") }}
          </div>
          <component
            v-else-if="element.type === 'component' && element.resolvedComponent"
            :is="element.resolvedComponent"
            v-bind="element.resolvedProps"
            class="pause-content-component"
            @focus-side-panel="onFocusSidePanel"
            @clear-focus-side-panel="onClearFocusSidePanel"
          />
        </div>
        <div v-if="!mainPanelResolvedContent.length" class="pause-empty-content">
          <span v-if="routeDataStore.status === 'error'">
            Error occured while loading the route.<br/>
            {{ routeDataStore.error }}
          </span>
          <span v-else-if="routeDataStore.status === 'mounted-ready'">
            No layout data was received from the router.
          </span>
          <span v-else>
            {{ $t("ui.common.loading.short") }}
          </span>
        </div>
      </div>
    </template>

    <template #card2>
      <div v-if="activeModTab" class="pause-side-card">
        <component
          v-if="activeModCard2"
          :key="`${modManager.refreshToken}:${activeModCard2.componentName}`"
          :is="activeModCard2.component"
          v-bind="activeModCard2.props"
          class="pause-content-component"
        />
      </div>
      <div v-else-if="hasSecondCard" class="pause-side-card">
        <div
          v-for="element in sidePanelResolvedContent"
          :key="element.key"
          class="pause-content-item"
        >
          <BngCardHeading v-if="element.type === 'title'" type="line">
            {{ $tt(element.text || element.title || element.id) }}
          </BngCardHeading>
          <div v-else-if="element.type === 'text'" class="pause-content-text">
            {{ $tt(element.text || element.description || "") }}
          </div>
          <component
            v-else-if="element.type === 'component' && element.resolvedComponent"
            :is="element.resolvedComponent"
            v-bind="element.resolvedProps"
            class="pause-content-component"
          />
        </div>
      </div>
    </template>

    <template #buttons-left>
      <div v-if="pauseRailHasActions" class="pause-left-rails" v-bng-blur>
        <PauseRail
          v-bng-scoped-nav="{
            scopeId: 'pause-left-rails',
            type: SCOPE_TYPES.CONTAINER,
            //TODO: This will not be a computed property and only evaluated once. Turn into a comptuted property
            preferAutoFocus: getScopePreferAutoFocus('pause-left-rails'),
            bubbleWhitelistEvents: PAUSE_BUBBLE_EVENTS,
            wrapNavigation: WRAP_NAVIGATION.VERTICAL,
            canDeactivate: canDeactivatePauseExitScope,
            canPreventNavigationEscape: direction => shouldPreventRailNavigationEscape('pause-left-rails', direction),
            onPreventedNavigationEscape: payload => onPreventedRailNavigationEscape('pause-left-rails', payload),
          }"
          :groups="layoutRail"
          :selected-action-id="activeModButtonId"
          @focus-side-panel="onFocusSidePanel"
          @clear-focus-side-panel="onClearFocusSidePanel"
        />
      </div>
    </template>

    <template #side-tasklist v-if="tasklistStore.hasItems">
      <div class="pause-tasklist">
        <component :is="tasklist" class="pause-tasklist-content" />
      </div>
    </template>

  </LayoutMenu>
</template>

<script setup>
import { ref, computed, inject, unref, watch, nextTick, onMounted, onUnmounted } from "vue"
import { useRoute } from "vue-router"
import { vBngBlur, vBngUiNavLabel, vBngScopedNav } from "@/common/directives"
import { LayoutMenu } from "@/common/layouts"
import { BngServiceProvidersUser, BngCardHeading } from "@/common/components/base"
import { Background } from "@/common/components/utility"
import SysInfo from "@/services/sysInfo"
import { useRouteDataStore } from "@/services/routeData"
import { activateRouteTargetScope, useScopedNav } from "@/services/scopedNav/api"
import { lua } from "@/bridge"
import PauseButton from "@/common/modules/pause/components/pauseButton.vue"
import PauseRail from "../components/PauseRail.vue"
import { tasklist } from "@/modules/apps"
import { useTasksStore } from "@/services/tasklistStore"
import { useEvents } from "@/services/events"
import { getComponent as getModComponent, refreshComponents, useModManager } from "@/services/modManager"
import logger from "@/services/logger"
import * as pauseContent from "../pauseContent.js"
import { SCOPE_TYPES, WRAP_NAVIGATION } from "@/services/scopedNav/types"
import { getRouteScopeMeta } from "@/services/scopedNav/routeIntegration"
import { consumeUINavNavigationIntent } from "@/services/crossfire"

defineOptions({ name: "Pause" })

const $simplemenu = inject("$simplemenu", ref(false))
const isSimpleMenu = computed(() => unref($simplemenu))

const ROOT_SCOPE_ID = "pause-root"
const MAIN_CARD_SCOPE_ID = "menu-content-card-1"
const LEFT_RAIL_SCOPE_ID = "pause-left-rails"
const PAUSE_BUBBLE_EVENTS = Object.freeze(["tab_l", "tab_r", "menu", "back"])

function isPauseMultiplayerRouteName(routeName) {
  return typeof routeName === "string" && routeName.startsWith("pause.multiplayer")
}

function shouldHidePauseTab(tab) {
  if (!isSimpleMenu.value) return false

  const routeName = tab?.screenId || tab?.routeName
  return isPauseMultiplayerRouteName(routeName)
}

const route = useRoute()
const routeDataStore = useRouteDataStore()
const tasklistStore = useTasksStore()
const modManager = useModManager()
const events = useEvents()
const bngVue = window.bngVue || { gotoGameState() {} }
const { activateScope, isActiveScope, requestScopeFocus } = useScopedNav()

const currentTime = ref("")
const selectedTabIndex = ref(0)
let currentTimeIntervalId
const lastMountedAckRouteName = ref("")
const focusedSidePanelId = ref(null)
const focusedSidePanelContent = ref(null)
let mountedAckRequestId = 0
let focusRepairRequestId = 0

const layoutMenuData = computed(() => routeDataStore.data?.layoutMenu || {})
const layoutHeader = computed(() => layoutMenuData.value.header || {})
const layoutTopbar = computed(() => layoutMenuData.value.topbar || {})
const layoutContent = computed(() => layoutMenuData.value.content || {})
const modRailGroups = computed(() => {
  if (!activeModTab.value) return null
  return [{
    id: activeModTab.value.tabId,
    actions: (activeModTab.value.buttons || []).map(button => ({
      id: button.id,
      label: button.label,
      icon: button.icon,
      enabled: true,
      visible: true,
      onSelect: () => { activeModButtonId.value = button.id },
    })),
  }]
})
const layoutRail = computed(() => modRailGroups.value || (Array.isArray(layoutContent.value.rail) ? layoutContent.value.rail : []))
const pauseRailHasActions = computed(() => layoutRail.value.some(group => Array.isArray(group?.actions) && group.actions.some(action => action?.visible !== false)))
const layoutNav = computed(() => layoutMenuData.value.nav || {})

const activeModTabId = ref(null)
const activeModButtonId = ref(null)
const activeModCard1 = ref(null)
const activeModCard2 = ref(null)
const activeModTab = computed(() => (
  activeModTabId.value ? (menuTabs.value.find(tab => tab.isModTab && tab.tabId === activeModTabId.value) || null) : null
))
const activeModButton = computed(() => activeModTab.value?.buttons?.find(button => button.id === activeModButtonId.value) || null)

function normalizeClassList(classValue) {
  if (!classValue) return []
  if (Array.isArray(classValue)) return classValue.filter(Boolean)
  return [classValue]
}

const routeMainCardClasses = computed(() => {
  return normalizeClassList(layoutContent.value.data?.mainCardClass)
})
const routeSideCardClasses = computed(() => {
  return normalizeClassList(layoutContent.value.data?.sideCardClass)
})

// snapshots of mod tab metadata, so mod reloads will work seamlessly
const liveModTabs = ref(null)
let liveModTabsRequestId = 0

async function refreshLiveModTabs() {
  const requestId = ++liveModTabsRequestId
  try {
    const tabs = await lua.extensions.ui_pause_actions.getVisibleModTabs() || []
    if (requestId === liveModTabsRequestId) liveModTabs.value = tabs
  } catch {
    if (requestId === liveModTabsRequestId && liveModTabs.value === null) liveModTabs.value = []
  }
}

function onPauseModActionsChanged(tabs) {
  liveModTabsRequestId++
  liveModTabs.value = Array.isArray(tabs) ? tabs : []
}

events.on("PauseModActionsChanged", onPauseModActionsChanged)

function mapPauseMenuTab(tab, index) {
  const vueRouteName = tab.screenId || tab.routeName
  return {
    ...tab,
    routeName: vueRouteName,
    luaRouteName: tab.routeName,
    index,
    heading: tab.label || tab.heading || tab.routeName || `Tab ${index + 1}`,
  }
}

const filterVisiblePauseTabs = tabs =>
  !Array.isArray(tabs) ? [] : tabs
  .filter(tab => tab?.visible !== false)
  .filter(tab => !shouldHidePauseTab(tab))

const menuTabs = computed(() => {
  const routeTabs = layoutTopbar.value.tabs || []
  const nativeTabs = filterVisiblePauseTabs(routeTabs.filter(tab => !tab.isModTab))
  const modTabs = filterVisiblePauseTabs(
    liveModTabs.value ?? routeTabs.filter(tab => tab.isModTab)
  )
  return [...nativeTabs, ...modTabs].map(mapPauseMenuTab)
})
const breadcrumbItems = computed(() => layoutHeader.value.breadcrumbs || [])
const pauseHeadingText = computed(() => layoutHeader.value.heading || "Pause")
const tabLeftHintLabel = computed(() => layoutTopbar.value.hints?.tabLeft || "Previous Tab")
const tabRightHintLabel = computed(() => layoutTopbar.value.hints?.tabRight || "Next Tab")
const layoutNavAutoFocus = computed(() => layoutNav.value.autoFocus !== false)
const pauseRootNavOptions = computed(() => ({
  bubbleWhitelistEvents: PAUSE_BUBBLE_EVENTS,
  canIgnoreEvent: onPauseRootNavEvent,
  canDeactivate: canDeactivatePauseExitScope,
}))

const mainCardRailTargetsByDirection = {
  left: { scopeId: LEFT_RAIL_SCOPE_ID, hasItems: () => pauseRailHasActions.value },
}

const railExitDirections = {
  [LEFT_RAIL_SCOPE_ID]: "right",
  "pause-right-rails": "left",
  "pause-bottom-rails": "top",
}

const crossfireDirectionToPauseDirection = {
  left: "left",
  right: "right",
  up: "top",
  down: "bottom",
}

const mainPanelContent = computed(() => {
  const content = layoutContent.value.main || []
  if (route.name !== "pause.career" || !Array.isArray(content)) return content
  return content.filter(element => element?.componentName !== "MilestoneDigest" && element?.id !== "milestoneDigest")
})
const focusSidePanelContents = computed(() => layoutContent.value.data?.focusSidePanelContents || {})
const sidePanelContent = computed(() => {
  const focusedContent = focusedSidePanelContent.value || (focusedSidePanelId.value ? focusSidePanelContents.value[focusedSidePanelId.value] : null)
  let content = focusedContent
  if (!Array.isArray(content)) {
    const side = layoutContent.value.side || []
    content = Array.isArray(side[0]) ? side[0] : side
  }
  if (!isSimpleMenu.value || !Array.isArray(content)) return content
  return content.filter(element => !element?.hideInSimpleMenu)
})
const focusedSideCardClasses = computed(() => {
  const focusedContent = focusedSidePanelContent.value || (focusedSidePanelId.value ? focusSidePanelContents.value[focusedSidePanelId.value] : null)
  if (!Array.isArray(focusedContent)) return normalizeClassList(focusedContent?.sideCardClass)

  return focusedContent.flatMap(element => normalizeClassList(element?.sideCardClass))
})
watch(
  () => layoutTopbar.value.selectedTab,
  selected => {
    if (typeof selected === "number") {
      selectedTabIndex.value = selected
    }
  },
  { immediate: true }
)

watch(
  () => route.name,
  () => {
    focusedSidePanelId.value = null
    focusedSidePanelContent.value = null
    activeModTabId.value = null
    activeModButtonId.value = null
  }
)

function toModCard(componentName, data, props) {
  if (!data?.component) return null
  return {
    componentName,
    component: data.component,
    props: props && typeof props === "object" ? props : {},
  }
}

async function resolveModCard(componentName, props, refresh = false) {
  if (!componentName) return null
  try {
    const data = await getModComponent(componentName, refresh)
    return toModCard(componentName, data, props)
  } catch (err) {
    logger.error("[MOD] Failed to resolve pause mod component", componentName, err)
    return null
  }
}

async function refreshActiveModCards(refresh = false) {
  const button = activeModButton.value
  const card2ComponentName = button?.card2ComponentName || activeModTab.value?.card2ComponentName
  const card2Props = button?.card2Props ?? activeModTab.value?.card2Props

  if (refresh) {
    const paths = [button?.componentName, card2ComponentName].filter(Boolean)
    const compiled = paths.length ? await refreshComponents(paths) : new Map()
    activeModCard1.value = button?.componentName
      ? toModCard(button.componentName, compiled.get(button.componentName), button?.props)
      : null
    activeModCard2.value = card2ComponentName
      ? toModCard(card2ComponentName, compiled.get(card2ComponentName), card2Props)
      : null
    return
  }

  activeModCard1.value = await resolveModCard(button?.componentName, button?.props, false)
  activeModCard2.value = card2ComponentName ? await resolveModCard(card2ComponentName, card2Props, false) : null
}

watch(activeModButton, () => refreshActiveModCards(), { immediate: true })

watch(() => modManager.refreshToken, async () => {
  await refreshLiveModTabs()
  await refreshActiveModCards(true)
})

watch(
  () => [isSimpleMenu.value, route.name],
  ([simpleMenuEnabled, routeName]) => {
    if (!simpleMenuEnabled) return
    if (!isPauseMultiplayerRouteName(routeName)) return

    void bngVue.gotoGameState("pause")
  },
  { immediate: true }
)

function buildResolvedPauseElementTree(panelName, elements) {
  return (Array.isArray(elements) ? elements : []).map((element, index) => {
    const type = element?.type
    const componentName = String(element?.componentName || "")
    const resolvedComponent = type === "component" ? (pauseContent[componentName] || null) : null
    const resolvedProps = element?.props && typeof element.props === "object" ? { ...element.props } : {}
    return {
      ...element,
      resolvedComponent,
      resolvedProps,
      key: element?.id || `${panelName}-${index}-${type || "unknown"}-${componentName || element?.text || ""}`,
    }
  })
}

const mainPanelResolvedContent = computed(() => buildResolvedPauseElementTree("main", mainPanelContent.value))
const sidePanelResolvedContent = computed(() => buildResolvedPauseElementTree("side", sidePanelContent.value))
const hasSecondCard = computed(() => {
  if (activeModTab.value) return !!activeModCard2.value
  return sidePanelResolvedContent.value.some(element =>
    element.type === "title"
      || element.type === "text"
      || (element.type === "component" && element.resolvedComponent)
  )
})
const shouldHideEmptyMainCard = computed(() => routeDataStore.status === "mounted-ready" && mainPanelResolvedContent.value.length === 0)
const showMainCard = computed(() => !!activeModTab.value || !shouldHideEmptyMainCard.value)
const mainCardClass = computed(() => activeModTab.value ? {} : ({
  "menu-content-card-1--vehicle-spawned": route.name === "pause.manageVehicles",
  ...Object.fromEntries(routeMainCardClasses.value.map(className => [className, true])),
}))
const sideCardClass = computed(() => activeModTab.value ? {} : ({
  ...Object.fromEntries(routeSideCardClasses.value.map(className => [className, true])),
  ...Object.fromEntries(focusedSideCardClasses.value.map(className => [className, true])),
}))

function shouldRepairMainCardFocus() {
  if (typeof document === "undefined") return false
  const activeElement = document.activeElement
  return !activeElement || activeElement === document.body || !document.contains(activeElement)
}

function waitForAnimationFrame() {
  if (typeof window === "undefined" || typeof window.requestAnimationFrame !== "function") {
    return Promise.resolve()
  }
  return new Promise(resolve => window.requestAnimationFrame(resolve))
}

function activatePauseScope(scopeId, reason) {
  if (!scopeId) return false
  activateScope(scopeId, { reason, force: true })
  return true
}

function shouldLetCareerPathsOwnReturnFocus() {
  if (route.name !== "pause.career") return false
  return !!(routeDataStore.route?.params?.focusPathId || (typeof window !== "undefined" && window.__pauseCareerFocusPathId))
}

function getScopeMeta(scopeId) {
  return getRouteScopeMeta(routeDataStore, scopeId) || {}
}

function getScopePreferAutoFocus(scopeId) {
  return getScopeMeta(scopeId).preferAutoFocus === true
}

function getEscapeTargetScopeId(scopeId, direction) {
  const escapeTargets = getScopeMeta(scopeId).escapeTargets
  const targetScopeId = escapeTargets?.[direction]
  return typeof targetScopeId === "string" && targetScopeId ? targetScopeId : null
}

async function focusEscapeTargetScope(targetScopeId, reason) {
  const requestId = ++focusRepairRequestId
  const parentScopeId = getScopeMeta(targetScopeId).parentScopeId

  if (parentScopeId) {
    activatePauseScope(parentScopeId, reason)
    if (requestScopeFocus(parentScopeId, `[bng-scoped-nav="${targetScopeId}"]`, { reason })) {
      return true
    }

    await nextTick()
    await waitForAnimationFrame()

    if (requestId !== focusRepairRequestId) return false
    return requestScopeFocus(parentScopeId, `[bng-scoped-nav="${targetScopeId}"]`, { reason })
  }

  return activatePauseScope(targetScopeId, reason)
}

function isMainCardShellFocused() {
  if (typeof document === "undefined") return false
  const mainCard = document.querySelector(`[bng-scoped-nav="${MAIN_CARD_SCOPE_ID}"]`)
  return !!mainCard && document.activeElement === mainCard
}

function consumePauseNavIntent(event) {
  if (!event?.detail || event.detail.bubbled) return null

  const intent = consumeUINavNavigationIntent(event.detail)
  if (!intent) return null

  if (intent.consumeOnly) {
    return { axis: intent.axis, scalar: true, consumeOnly: true }
  }

  const direction = crossfireDirectionToPauseDirection[intent.direction]
  if (!intent.active) return null
  if (!direction) return null

  return {
    axis: intent.axis,
    direction,
    scalar: intent.scalar,
  }
}

function activateRailFromMainCard(event) {
  const intent = consumePauseNavIntent(event)
  if (!intent) return false
  if (intent.consumeOnly) return true

  const target = mainCardRailTargetsByDirection[intent.direction]
  if (target?.hasItems()) {
    activatePauseScope(target.scopeId, "pause-card-to-rail")
    return true
  }

  return intent.scalar
}

function onPauseRootNavEvent(event) {
  if (!isMainCardShellFocused()) return false
  return activateRailFromMainCard(event)
}

function onMainCardNavEvent(event) {
  if (!isMainCardShellFocused()) return false
  return activateRailFromMainCard(event)
}

/** On root pause, B/Circle should resume — don't rely solely on pauseExitHandler. */
function canDeactivatePauseExitScope() {
  if (route.name !== "pause") return true
  void lua.extensions.ui_router.navigate("play")
  return false
}

function shouldPreventRailNavigationEscape(scopeId, direction) {
  const targetScopeId = getEscapeTargetScopeId(scopeId, direction)
  if (targetScopeId) return true

  return direction !== railExitDirections[scopeId]
}

function onPreventedRailNavigationEscape(scopeId, payload) {
  const direction = payload?.direction
  if (!direction) return

  const targetScopeId = getEscapeTargetScopeId(scopeId, direction)
  if (!targetScopeId) return

  void focusEscapeTargetScope(targetScopeId, "pause-rail-escape-target")
}

async function focusMainCardEntryIfFocusMissing() {
  const requestId = ++focusRepairRequestId

  await nextTick()
  await waitForAnimationFrame()

  if (requestId !== focusRepairRequestId) return false
  if (!isActiveScope(MAIN_CARD_SCOPE_ID)) return false
  if (!shouldRepairMainCardFocus()) return false

  return requestScopeFocus(MAIN_CARD_SCOPE_ID)
}

async function focusPauseRailEntryIfTargeted(originalRouteName) {
  const requestId = ++focusRepairRequestId

  await nextTick()
  await waitForAnimationFrame()

  if (requestId !== focusRepairRequestId) return false
  if (originalRouteName && route.name !== originalRouteName) return false
  if (routeDataStore.targetScope !== LEFT_RAIL_SCOPE_ID) return false
  if (!pauseRailHasActions.value) return false

  activatePauseScope(LEFT_RAIL_SCOPE_ID, "pause-route-default-rail")
  return requestScopeFocus(LEFT_RAIL_SCOPE_ID)
}
async function focusMainCardShellIfRootActive(originalRouteName) {
  const requestId = ++focusRepairRequestId

  await nextTick()
  await waitForAnimationFrame()

  if (requestId !== focusRepairRequestId) return false
  if (originalRouteName && route.name !== originalRouteName) return false
  if (!isActiveScope(ROOT_SCOPE_ID)) return false

  return requestScopeFocus(ROOT_SCOPE_ID, `[bng-scoped-nav="${MAIN_CARD_SCOPE_ID}"]`, {
    reason: "pause-root-default-card",
  })
}

function onBeforeNavigate(event) {
  if (!event || event.type !== "tab-change") return
  if (event.sync === true) return
  const nextIndex = event.tab?.index
  const nextTab = menuTabs.value[nextIndex]
  if (!nextTab || nextTab.enabled === false) {
    event.preventDefault()
  }
}

function onFocusSidePanel(payload) {
  const panelId = typeof payload === "string" ? payload : payload?.id
  const content = typeof payload === "object" && Array.isArray(payload.content) ? payload.content : null
  if (!panelId) return
  if (!content && !focusSidePanelContents.value[panelId]) return
  focusedSidePanelId.value = panelId
  focusedSidePanelContent.value = content
}

function onClearFocusSidePanel(panelId) {
  if (!panelId || focusedSidePanelId.value === panelId) {
    focusedSidePanelId.value = null
    focusedSidePanelContent.value = null
  }
}

async function onTabChange(tab, prevTab, meta) {
  if (meta?.sync === true) return
  const nextIndex = tab?.index ?? selectedTabIndex.value
  const nextTab = menuTabs.value[nextIndex]
  if (!nextTab || nextTab.enabled === false) return

  if (nextTab.isModTab) {
    activeModTabId.value = nextTab.tabId
    activeModButtonId.value = nextTab.buttons?.[0]?.id ?? null
    return
  }

  activeModTabId.value = null
  activeModButtonId.value = null
  if (!nextTab.routeName) return
  if (route.name === nextTab.routeName) return
  await bngVue.gotoGameState(nextTab.luaRouteName)
}

async function onBreadcrumbClick(item) {
  if (!item || !item.routeName) return
  const navName = item.routeName
  if (item.params) {
    await bngVue.gotoGameState(navName, { params: item.params })
    return
  }
  await bngVue.gotoGameState(navName)
}

async function onBreadBack() {
  if (route.name === "pause") {
    await lua.extensions.ui_router.navigate("play")
    return
  }
  await lua.extensions.ui_router.back()
}

function updateCurrentTime() {
  const now = new Date()
  currentTime.value = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
}

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || routeName === "unknown" || routeName === "__legacyAngular") return

  const requestId = ++mountedAckRequestId
  await nextTick()

  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }

  if (requestId !== mountedAckRequestId) return
  if (route.name !== routeName) return
  const canonicalRoute = window.__luaRouter__?._pendingCanonicalRoute || routeName
  if (lastMountedAckRouteName.value === canonicalRoute) return

  const result = await lua.extensions.ui_router.routeMounted(canonicalRoute)
  lastMountedAckRouteName.value = canonicalRoute
  if (result?.success) {
    window.__luaRouter__._pendingCanonicalRoute = null
    if (shouldLetCareerPathsOwnReturnFocus()) return
    activateRouteTargetScope()
    if (routeDataStore.targetScope === ROOT_SCOPE_ID) {
    //  focusMainCardShellIfRootActive(routeName)
    } else if (routeDataStore.targetScope === LEFT_RAIL_SCOPE_ID) {
      focusPauseRailEntryIfTargeted(routeName)
    } else if (routeDataStore.targetScope === MAIN_CARD_SCOPE_ID || isActiveScope(MAIN_CARD_SCOPE_ID)) {
      focusMainCardEntryIfFocusMissing()
    }
  }
}

watch(
  () => route.fullPath,
  async () => {
    lastMountedAckRouteName.value = ""
    await notifyRouteMountedWhenReady()
  },
  { immediate: true }
)

watch(
  () => [routeDataStore.status, routeDataStore.routeName],
  async ([status, routeName]) => {
    if (status !== "enter-ready") return
    if (!routeName || routeName !== route.name) return
    lastMountedAckRouteName.value = ""
    await notifyRouteMountedWhenReady()
  }
)

onMounted(() => {
  updateCurrentTime()
  currentTimeIntervalId = window.setInterval(updateCurrentTime, 1000)
  void refreshLiveModTabs()
})

onUnmounted(() => {
  focusRepairRequestId += 1
  if (currentTimeIntervalId) window.clearInterval(currentTimeIntervalId)
})
</script>

<style lang="scss" scoped>
.pause-layout {
  :deep(.menu-content-card > .card-cnt) {
    flex: 1 1 auto;
    min-height: 100%;
  }

  :deep(.menu-content-card) {
    --bng-bg-border-radius: var(--bng-corners-2);
    --bng-bg-border-width: 0;
    --bng-card-content-bg: var(--bng-cool-gray-900);
    --bng-card-content-bg-opacity: 0.9;
  }

  :deep(.menu-content-card-1--no-scroll) {
    height: 100%;

    > .card-cnt {
      min-height: 0;
    }
  }

  :deep(.menu-content-card-1--no-scroll) .pause-main-card,
  :deep(.menu-content-card-1--no-scroll) .pause-content-item,
  :deep(.menu-content-card-1--no-scroll) .pause-content-component {
    flex: 1 1 auto;
    min-height: 0;
    overflow: hidden;
  }

  .pause-main-card,
  .pause-side-card {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    flex: 1 1 auto;
    min-height: 100%;
    width: 100%;
    overflow-y: auto;
  }


  .pause-content-item {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    overflow: visible;

    &:only-child {
      flex: 1 1 auto;
      min-height: 0;
    }
  }

  .pause-content-item:only-child > .pause-content-component {
    flex: 1 1 auto;
    min-height: 0;
  }

  .pause-content-text {
    font-size: 0.9rem;
    color: rgba(var(--bng-off-white-rgb), 0.85);
    padding: 0 0.5rem;
  }

  .pause-content-component {
    max-height: none;
    overflow: visible;
  }

  .pause-empty-content {
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    min-height: 100%;
    opacity: 0.75;
    padding: 0.5rem 0;
  }

  .pause-left-rails,
  .pause-right-rails {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .pause-tasklist {
    flex: 0 0 30rem;
    width: 30rem;
    min-width: 0;
  }

  .pause-tasklist-content {
    min-height: 0;
  }

  .system-info {
    --bng-bg-enabled: var(--bng-off-black);
    --bng-bg-enabled-opacity: 0.6;
    --bng-bg-border-radius: var(--bng-corners-1);
    --bng-bg-border-width: 0;

    display: inline-flex;
    align-items: center;
    gap: 1em;
    color: var(--bng-off-white);
    pointer-events: auto;
    user-select: none;
    align-self: flex-start;
    font-size: 1em;
    height: 2.5em;
    padding: 0 1em 0 0;
    position: relative;
    isolation: isolate;
    z-index: 2;

    .system-time {
      font-family: var(--fnt-mono);
      font-size: 1.25em;
      font-weight: 200;
      padding-top: 0.2em;
    }

    .username {
      display: inline-flex;
      align-items: center;
      gap: 0.25em;
    }
  }

  .topbar-right-meta {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 0.2rem;
  }

  .gamepad-nav-wip-label {
    text-align: center;
    font-size: 0.7rem;
    line-height: 1.1;
    background-color: rgba(var(--bng-off-white-rgb), 0.15);
    padding: 0.25em 0.5em;
    pointer-events: none;
    user-select: none;
  }
}
</style>
