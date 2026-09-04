<template>
  <ComputerWrapper
    :title="$translate.instant('ui.career.shared.pathTuning')"
    @back="confirmCancel">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'career-tuning', canDeactivate: tuningBack }"
      class="tuning-card"
      ref="elCard"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      :active="isTuningActive"
      :heading="$translate.instant('ui.career.shared.pathTuning')"
      heading-hint-start-icon="arrowLargeRight"
      heading-hint-start-binding-event="context">
      <div v-if="isTuningTent && activeVehicle" class="tuning-vehicle-selector">
        <BngButton
          v-if="showVehicleSelectorButtons"
          class="vehicle-selector-button"
          :icon="icons.arrowLargeLeft"
          :accent="ACCENTS.ghost"
          :disabled="switchingVehicle || exitInProgress"
          bng-no-nav="true"
          v-bng-on-ui-nav:tab_l.asMouse
          @click="cycleVehicle(-1)">
          <BngBinding ui-event="tab_l" deviceMask="xinput" />
        </BngButton>
        <div class="vehicle-selector-label">
          <span class="vehicle-selector-caption">Tuning vehicle</span>
          <strong>{{ switchingVehicle ? "Switching vehicle…" : activeVehicle.niceName }}</strong>
          <span v-if="switchError" class="vehicle-selector-error">{{ switchError }}</span>
        </div>
        <BngButton
          v-if="showVehicleSelectorButtons"
          class="vehicle-selector-button"
          :icon="icons.arrowLargeRight"
          :accent="ACCENTS.ghost"
          :disabled="switchingVehicle || exitInProgress"
          bng-no-nav="true"
          v-bng-on-ui-nav:tab_r.asMouse
          @click="cycleVehicle(1)">
          <BngBinding ui-event="tab_r" deviceMask="xinput" />
        </BngButton>
      </div>
      <Tuning
        ref="tuningComponentRef"
        :class="{ 'vehicle-switching': switchingVehicle }"
        :button-target="elCard && elCard.buttonsContainer"
        :close-button="false"
        allow-context-nav />
      <template #footer></template>
    </ComputerPanel>

    <template #side>
      <ShoppingCart
        v-bng-scoped-nav="{ scopeId: 'career-tuning-cart' }"
        :active="isCartActive"
        :cart-data="cartData"
        :player-money="tuningStore.shoppingData.playerMoney"
        :confirm-button-text="$translate.instant('ui.career.shared.confirm')"
        v-bng-on-ui-nav:context="switchToTuning"
        @apply="applyShopping"
        @cancel="confirmCancel"
        @remove-item="removeCartItem" />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from "vue"
import { BngBinding, BngButton, ACCENTS, icons } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { useRoute } from "vue-router"
import { useScopedNav, activateRouteTargetScope } from "@/services/scopedNav/api"
import { $translate } from "@/services/translation"
import { openConfirmation, openProgress } from "@/services/popup"
import { useUINavBlocker } from "@/services/uiNavTracker"

import { useTuningStore } from "@/modules/vehicleConfig/stores/tuningStore"

import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import Tuning from "@/modules/vehicleConfig/components/Tuning.vue"
import ShoppingCart from "../components/ShoppingCart.vue"

const tuningStore = useTuningStore()
const route = useRoute()
const { events } = useBridge()

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const { switchScope, current } = useScopedNav()

const isCartActive = computed(() => current.value?.id === "career-tuning-cart")
const isTuningActive = computed(() => current.value?.id === "career-tuning")

const switchToCart = () => switchScope("career-tuning-cart")
const switchToTuning = () => switchScope("career-tuning")

// BACK from the tuning scope must run the cancel/confirm flow instead of letting
// the route back bypass tuning cleanup. Returning false stops scope deactivation.
const tuningBack = () => {
  confirmCancel()
  return false
}

const CANCEL_MESSAGE = $translate.instant("ui.career.shared.cancelShoppingMessage")
const CONFIRM_BUTTONS = [
  { label: $translate.instant("ui.common.yes"), value: true },
  { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
]

const SWITCH_VEHICLE_MESSAGE = "Switch tuning vehicles?<br />Any unpurchased tuning changes on this vehicle will be discarded."
const exitInProgress = ref(false)

const confirmCancel = async () => {
  if (exitInProgress.value || switchingVehicle.value) return
  if (!(tuningStore.shoppingData.shoppingCart && tuningStore.shoppingData.shoppingCart.items.length) || await openConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)) {
    exitInProgress.value = true
    // The backend closes the route after any applied preview has been restored.
    // Show progress immediately without adding a fixed delay to the exit path.
    openProgress("", $translate.instant("ui.career.shared.pathTuning"), { indeterminate: true, cancellable: false, timeout: 3 })
    cancelShopping()
  }
}

const cartData = computed(() => {
  const cart = tuningStore.shoppingData ? tuningStore.shoppingData.shoppingCart : null
  const res = { total: 0, taxes: 0, items: [] }
  if (cart) {
    res.total = cart.total
    res.taxes = cart.taxes
    if (Array.isArray(cart.items)) {
      res.items = cart.items.map(item => ({
        type: item.type || (item.level === 1 && "item"),
        level: item.level,
        name: item.title,
        price: item.price,
        priceHide: !item.price,
        removeShow: !!item.varName,
        varName: item.varName,
      }))
    }
  }
  return res
})

const elCard = ref()
const tuningComponentRef = ref(null)

const tuningSession = ref({ vehicles: [], activeInventoryId: null, isTuningTent: false })
const switchingVehicle = ref(false)
const switchError = ref("")

const isTuningTent = computed(() => tuningSession.value.isTuningTent === true)
const tuningVehicles = computed(() => Array.isArray(tuningSession.value.vehicles) ? tuningSession.value.vehicles : [])
const activeVehicleIndex = computed(() => tuningVehicles.value.findIndex(vehicle =>
  String(vehicle.inventoryId) === String(tuningSession.value.activeInventoryId)
))
const activeVehicle = computed(() => tuningVehicles.value[activeVehicleIndex.value] || tuningVehicles.value[0] || null)
const showVehicleSelectorButtons = computed(() => tuningVehicles.value.length > 1)

function hasUnpurchasedChanges() {
  const cartItems = tuningStore.shoppingData?.shoppingCart?.items
  const exposedDirty = tuningComponentRef.value?.isChanged
  const slidersDirty = typeof exposedDirty === "object" && exposedDirty !== null ? exposedDirty.value : exposedDirty
  return !!(Array.isArray(cartItems) && cartItems.length) || slidersDirty === true
}

async function cycleVehicle(offset) {
  if (!isTuningTent.value || !showVehicleSelectorButtons.value || switchingVehicle.value || exitInProgress.value) return false

  const currentIndex = Math.max(0, activeVehicleIndex.value)
  const nextIndex = (currentIndex + offset + tuningVehicles.value.length) % tuningVehicles.value.length
  const target = tuningVehicles.value[nextIndex]
  if (!target || String(target.inventoryId) === String(tuningSession.value.activeInventoryId)) return false

  if (hasUnpurchasedChanges() && !await openConfirmation(null, SWITCH_VEHICLE_MESSAGE, CONFIRM_BUTTONS)) {
    return false
  }

  switchingVehicle.value = true
  switchError.value = ""
  try {
    const result = await lua.career_modules_tuning.switchVehicle(Number(target.inventoryId))
    if (result?.success) return false
  } catch {
    // The same feedback is appropriate for a stale vehicle and a bridge failure.
  }

  if (switchingVehicle.value) {
    switchingVehicle.value = false
    switchError.value = "That vehicle is no longer available in the tuning area."
  }
  return false
}

async function refreshTuningSession(data = null) {
  const nextSession = data || await lua.career_modules_tuning.getTuningSessionData()
  if (nextSession) tuningSession.value = nextSession
}

async function onTuningVehicleChanged(data) {
  if (!data?.success) {
    switchingVehicle.value = false
    switchError.value = "Unable to load tuning data for that vehicle."
    return
  }

  try {
    await refreshTuningSession(data)
    await tuningStore.requestInitialData()
  } catch {
    switchError.value = "Unable to load tuning data for that vehicle."
  } finally {
    switchingVehicle.value = false
  }
}

const applyShopping = () => lua.career_modules_tuning.applyShopping()
const cancelShopping = () => lua.career_modules_tuning.cancelShopping()
const removeCartItem = (item) => lua.career_modules_tuning.removeVarFromShoppingCart(item.varName)

// Tuning buckets arrive from Lua after mount. Delay the manual routeMounted ack
// and scope activation until the data is present and rendered so the tuning
// autofocus target lands on a navigable entry.
const isTuningReady = computed(() => !!tuningStore.buckets && Object.keys(tuningStore.buckets).length > 0)

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || routeName === "unknown" || routeName === "__legacyAngular") return
  if (!isTuningReady.value) return

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
  if (requestId !== mountedAckRequestId) return
  if (route.name !== routeName) return
  if (!result?.success) return

  lastMountedAckRouteName.value = canonicalRoute
  if (window.__luaRouter__) window.__luaRouter__._pendingCanonicalRoute = null

  activateRouteTargetScope()
}

watch(
  () => route.fullPath,
  () => {
    lastMountedAckRouteName.value = ""
    notifyRouteMountedWhenReady()
  },
  { immediate: true }
)

watch(isTuningReady, ready => {
  if (ready) notifyRouteMountedWhenReady()
})

onMounted(() => {
  events.on("careerTuningVehicleChanged", onTuningVehicleChanged)
  events.on("tuningRequestExit", confirmCancel)
  refreshTuningSession().catch(() => {
    switchError.value = "Unable to load vehicles in the tuning area."
  })
})

onUnmounted(() => {
  events.off("careerTuningVehicleChanged", onTuningVehicleChanged)
  events.off("tuningRequestExit", confirmCancel)
})
</script>

<style scoped lang="scss">
.tuning-card {
  // ComputerPanel defaults to height: fit-content via --bng-card-height.
  // Without this, Live Wheel Data grows the panel and clips Apply/toggles.
  --bng-card-height: 100%;
  overflow: hidden;
  width: 40%;
  height: 100%;
  max-height: 100%;

  &:deep(.panel-content) {
    background-color: rgba(0, 0, 0, 0);
    flex: 1 1 0;
    height: auto;
    min-height: 0;
    max-height: 100%;
    overflow: hidden;
  }

  &:deep(.innerTuningCard) {
    flex: 1 1 0;
    min-height: 0;
    max-height: 100%;
    height: 100%;
    overflow: hidden;
  }
}

.tuning-vehicle-selector {
  flex: 0 0 auto;
  display: flex;
  align-items: stretch;
  min-height: 3.5rem;
  margin: 0.5rem 0.5rem 0;
  overflow: hidden;
  color: white;
  background: var(--bng-black-6);
  border: 1px solid rgba(255, 255, 255, 0.15);
  border-radius: var(--bng-corners-1);
}

.vehicle-selector-button {
  min-width: 3rem !important;
  justify-content: center;
  border-radius: 0;
}

.vehicle-selector-label {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  padding: 0.5rem 0.75rem;
  text-align: center;

  strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

.vehicle-selector-caption {
  color: var(--bng-cool-gray-300);
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.vehicle-selector-error {
  color: var(--bng-add-red-300);
  font-size: 0.75rem;
}

.vehicle-switching {
  opacity: 0.45;
  pointer-events: none;
}

:deep(.tuning-static) {
  padding-left: 0.5em;
}
</style>
