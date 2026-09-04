<template>
  <ComputerWrapper :title="$translate.instant('ui.career.shared.pathParts')" @back="close">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'part-shopping-categories' }"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      class="part-shopping-panel"
      tabindex="-1"
      :active="isPartShoppingActive"
      :heading="panelHeading"
      heading-hint-start-icon="arrowLargeRight"
      heading-hint-start-binding-event="context"
    >
      <!-- Keep panels mounted so each level restores its scroll position on back. -->
      <div class="panel-stack">
        <Categories
          v-show="activePanel === 'categories'"
          class="panel-layer"
          :cancel="confirmCancel"
        />
        <SlotList
          v-show="activePanel === 'slots'"
          class="panel-layer"
          :cancel="confirmCancel"
        />
        <PartsList
          v-show="activePanel === 'parts'"
          class="panel-layer"
          :cancel="confirmCancel"
        />
      </div>
    </ComputerPanel>
    <template #side>
      <ShoppingCart
        v-bng-scoped-nav="{ scopeId: 'part-shopping-cart' }"
        :active="isCartActive"
        :partShoppingData="partShoppingStore.partShoppingData"
        :cart-data="cartData"
        :player-money="partShoppingStore.partShoppingData.playerMoney"
        :confirm-button-text="$translate.instant('ui.career.shared.confirm')"
        :show-save-for-later="true"
        :restore-in-progress="!!partShoppingStore.partShoppingData.restoreInProgress"
        :restore-progress="partShoppingStore.partShoppingData.restoreProgress || { current: 0, total: 0 }"
        v-bng-on-ui-nav:context="switchToCategories"
        @apply="applyShopping"
        @cancel="confirmCancel"
        @save-for-later="confirmSaveForLater"
        @remove-item="removeCartItem"
      />
    </template>

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { computed, ref, watch, nextTick, onBeforeMount, onUnmounted } from "vue"
import { BngBinding, ACCENTS } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { useScopedNav, activateRouteTargetScope } from "@/services/scopedNav/api"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import { useBridge } from "@/bridge"
import { useRoute } from "vue-router"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"
import { useUINavBlocker } from "@/services/uiNavTracker"

import { usePartShoppingStore } from "../stores/partShoppingStore"
import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import ShoppingCart from "../components/ShoppingCart.vue"
import Categories from "../components/partShopping/Categories.vue"
import SlotList from "../components/partShopping/SlotList.vue"
import PartsList from "../components/partShopping/PartsList.vue"
import { callModLua } from "../utils/installLuaBridgeFallbacks"

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const partShoppingStore = usePartShoppingStore()
const { events, lua, units } = useBridge()

const route = useRoute()
const { switchScope, current } = useScopedNav()

const isCartActive = computed(() => current.value?.id === "part-shopping-cart")
const isPartShoppingActive = computed(() => current.value?.id === "part-shopping-categories")

const switchToCart = () => switchScope("part-shopping-cart")
const switchToCategories = () => switchScope("part-shopping-categories")

const CANCEL_MESSAGE = $translate.instant("ui.career.shared.cancelShoppingMessage")
const SAVE_FOR_LATER_MESSAGE = "Leave part customization?<br />Your build will be saved for later. The vehicle will return to its current installed state."
const CONFIRM_BUTTONS = [
  { label: $translate.instant("ui.common.yes"), value: true },
  { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
]

const confirmCancel = async () => {
  const cart = partShoppingStore.partShoppingData?.shoppingCart
  const hasItems = cart && cart.partsInList && cart.partsInList.length > 0

  if (!hasItems) {
    discardShopping()
    return
  }

  if (await openConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)) {
    discardShopping()
  }
}

const confirmSaveForLater = async () => {
  const cart = partShoppingStore.partShoppingData?.shoppingCart
  const hasItems = cart && cart.partsInList && cart.partsInList.length > 0
  if (!hasItems) return

  if (await openConfirmation(null, SAVE_FOR_LATER_MESSAGE, CONFIRM_BUTTONS)) {
    saveCartForLater()
  }
}

const getPartName = (item) => {
  return item.description.description + (item.partId ? " (Inventory)" : "")
}

const cartData = computed(() => {
  const cart = partShoppingStore.partShoppingData ? partShoppingStore.partShoppingData.shoppingCart : null
  const res = { total: 0, taxes: 0, items: [] }
  if (cart) {
    res.total = cart.total
    res.taxes = cart.taxes
    if (Array.isArray(cart.partsInList)) {
      res.items = cart.partsInList.map(item => ({
        name: getPartName(item),
        price: item.finalValue,
        extraInfo: item.partCondition?.odometer ? $translate.instant("ui.career.shared.mileagePrefix") + units.buildString("length", item.partCondition.odometer, 0) : undefined,
        removeShow: !!item.sourcePart,
        removeDisabled: !!partShoppingStore.partShoppingData.tutorialPartNames,
        containingSlot: item.containingSlot,
      }))
    }
  }
  return res
})

const applyShopping = () => lua.career_modules_partShopping.applyShopping()
const cancelShopping = () => lua.career_modules_partShopping.cancelShopping()
const discardShopping = () => callModLua("career_modules_partShopping.discardShopping")
const saveCartForLater = () => callModLua("career_modules_partShopping.saveCartForLater")
const removeCartItem = (item) => lua.career_modules_partShopping.removePartBySlot(item.containingSlot)

// Shopping data arrives from Lua after mount. Delay the manual routeMounted ack
// and scope activation until the data is present and rendered so the categories
// autofocus target lands on a navigable entry.
const isShoppingReady = computed(() => !!partShoppingStore.partShoppingData?.partTree)

// The backend prepares which panel the active route shows; render it directly.
const activePanel = computed(() => partShoppingStore.activePanel)

const panelHeading = computed(() => {
  if (activePanel.value === "categories") return $translate.instant("ui.career.shared.categories")
  if (activePanel.value === "slots") return $translate.instant("ui.career.partShopping.allParts")
  if (partShoppingStore.category === "cargo") return $translate.instant("ui.career.partShopping.cargo")
  const firstPart = partShoppingStore.filteredParts[0]
  if (firstPart) return partShoppingStore.partShoppingData.slotsNiceName[firstPart.containingSlot]
  return null
})

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || routeName === "unknown" || routeName === "__legacyAngular") return
  if (!isShoppingReady.value) return

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
  if (!result?.success) return
  if (window.__luaRouter__) window.__luaRouter__._pendingCanonicalRoute = null
  if (requestId !== mountedAckRequestId) return
  if (route.name !== routeName) return

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

watch(isShoppingReady, ready => {
  if (ready) {
    notifyRouteMountedWhenReady()
  }
})

const start = () => {
  partShoppingStore.requestInitialData()
  // UINavEvents.setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
}

const kill = () => {
  partShoppingStore.cancelShopping()
  // UINavEvents.clearFilteredEvents()
  getUINavServiceInstance().clearFilteredEvents()
  partShoppingStore.$dispose()
}

const close = () => lua.extensions.ui_router.back()

onBeforeMount(() => {
  start()
  events.on("partShoppingRequestExit", confirmCancel)
})
onUnmounted(() => {
  events.off("partShoppingRequestExit", confirmCancel)
  kill()
})
</script>

<style scoped lang="scss">
.part-shopping-panel {
  width: 30em;
  height: 100%;
}

.panel-stack {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.panel-layer {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.md-content {
  display: block;
  flex-direction: column;
  position: relative;
  width: 100%;
  text-align: center;
  height: 100%;
  overflow-y: hidden;
}

.profileStatus {
  border-radius: var(--bng-corners-2);
  position: absolute;
  top: 0;
  right: 0;
  color: white;
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}
</style>
