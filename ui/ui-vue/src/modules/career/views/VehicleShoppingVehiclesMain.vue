<template>
  <ComputerWrapper
    :path="[sellerName]"
    title="Available Vehicles"
    back
    @back="close"
  >
    <template #status>
      Free Inventory Slots: {{ store.vehicleShoppingData.numberOfFreeSlots || 0 }}
    </template>

    <div
      v-bng-scoped-nav="{ scopeId: 'vehicle-shopping-vehicles', preferAutoFocus: true }"
      class="vehicles-screen"
    >
      <VehicleList v-if="loaded" />
      <BngCard v-else>
        <BngCardHeading style="color: #fff">Please wait...</BngCardHeading>
      </BngCard>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { computed, nextTick, onMounted, ref, watch } from "vue"
import { BngCard, BngCardHeading } from "@/common/components/base"
import { lua } from "@/bridge"
import { useRoute } from "vue-router"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import { vBngScopedNav } from "@/common/directives"
import ComputerWrapper from "./ComputerWrapper.vue"
import VehicleList from "../components/vehicleShopping/VehicleList.vue"
import { useVehicleShoppingStore } from "../stores/vehicleShoppingStore"

const store = useVehicleShoppingStore()
const route = useRoute()
const loaded = computed(() => Object.keys(store.vehicleShoppingData || {}).length > 0)
const sellerName = computed(() => {
  if (store.vehicleShoppingData.currentSellerNiceName) return store.vehicleShoppingData.currentSellerNiceName
  const id = store.vehicleShoppingData.selectedSellerId || store.selectedSellerId
  const seller = (store.vehicleShoppingData.dealerships || []).find(item => String(item.id) === String(id))
  return seller?.name || "Buy Vehicles"
})

const close = () => lua.extensions.ui_router.back()

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || !loaded.value) return
  const requestId = ++mountedAckRequestId
  await nextTick()
  if (requestId !== mountedAckRequestId || route.name !== routeName) return

  const canonicalRoute = window.__luaRouter__?._pendingCanonicalRoute || routeName
  if (lastMountedAckRouteName.value === canonicalRoute) return
  const result = await lua.extensions.ui_router.routeMounted(canonicalRoute)
  lastMountedAckRouteName.value = canonicalRoute
  if (!result?.success) return
  if (window.__luaRouter__) window.__luaRouter__._pendingCanonicalRoute = null
  activateRouteTargetScope()
}

watch(() => route.fullPath, () => {
  lastMountedAckRouteName.value = ""
  notifyRouteMountedWhenReady()
}, { immediate: true })

watch(loaded, ready => {
  if (ready) notifyRouteMountedWhenReady()
})

onMounted(async () => {
  await store.requestVehicleShoppingData()
  const sellerId = store.vehicleShoppingData.currentSeller || store.vehicleShoppingData.selectedSellerId
  store.setSelectedSellerId(sellerId || "")
  await notifyRouteMountedWhenReady()
})
</script>

<style scoped lang="scss">
.vehicles-screen {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  max-width: 80rem;
}
</style>
