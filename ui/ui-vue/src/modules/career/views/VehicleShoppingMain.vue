<template>
  <ComputerWrapper
    :path="[vehicleShoppingStore.vehicleShoppingData.currentSellerNiceName || ('Vehicle Marketplace')]"
    :title="headerTitle"
    bng-ui-scope="vehicleShopping"
    v-bng-on-ui-nav:tab_l,tab_r="processTabInput"
    back @back="close"
  >
    <template #status>
      <span v-if="racingTeamBizId">team shopping · team ${{ teamBalanceText }}</span>
      <span v-else>Free Inventory Slots: {{ vehicleShoppingStore ? vehicleShoppingStore.vehicleShoppingData.numberOfFreeSlots : 0 }}</span>
    </template>

    <div class="flex-container">
      <div class="content" v-bng-blur="1"> <!-- content -->
        <Tabs class="bng-tabs" :class="{ 'single-tab': tabs.length === 1 }" :selectedIndex="selectedTab" @change="onTabsChange">
          <TabList />

          <div v-for="tab in tabs" :key="tab" :tab-heading="tab" :class="tab === buyVehicleTitle ? 'buying-tab-content' : 'marketplace-tab-content'">
            <template v-if="tab === buyVehicleTitle">
              <VehicleList v-if="loaded" />
              <BngCard v-else>
                <BngCardHeading style="color: #fff;">Please wait...</BngCardHeading>
              </BngCard>
            </template>
            <VehicleMarketplace v-else :racing-team-business-id="racingTeamBizId" />
          </div>
        </Tabs>
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick, computed, watch } from "vue"
import { BngCard, BngCardHeading } from "@/common/components/base"
import { Tabs, Tab, TabList } from "@/common/components/utility"
import { useVehicleShoppingStore } from "../stores/vehicleShoppingStore"
import ComputerWrapper from "./ComputerWrapper.vue"
import VehicleList from "../components/vehicleShopping/VehicleList.vue"
import VehicleMarketplace from "../components/vehicleShopping/VehicleMarketplace.vue"
import { lua } from "@/bridge"
import { useComputerStore } from "../stores/computerStore"
import { vBngOnUiNav } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useRouter, useRoute } from "vue-router"
import { vBngBlur } from "@/common/directives"

useUINavScope("vehicleShopping")

const buyVehicleTitle = 'Buy Vehicles'
const sellVehicleTitle = 'Sell Vehicles'

const computerStore = useComputerStore()
const vehicleShoppingStore = useVehicleShoppingStore()

const selectedTab = ref(0)
const selectedSellerId = ref("")

const router = useRouter()
const route = useRoute()

const loaded = ref(false)

const racingTeamBizId = computed(() => {
  const q = route.query.rtBiz
  if (q !== undefined && q !== null && String(q) !== "") return String(q)
  return String(vehicleShoppingStore?.vehicleShoppingData?.racingTeamBusinessId || "")
})

const teamBalanceText = computed(() => {
  const raw = vehicleShoppingStore?.vehicleShoppingData?.racingTeamBusinessMoney
  const n = Number(raw)
  if (!Number.isFinite(n)) return "—"
  return n.toLocaleString()
})

const tabs = computed(() => {
  let tabs = []
  const canBuy = vehicleShoppingStore.vehicleShoppingData.buyingAvailable ?? (props.buyingAvailable === 'true')
  const canUseMarketplace = vehicleShoppingStore.vehicleShoppingData.marketplaceAvailable ?? (props.marketplaceAvailable === 'true')
  if (canBuy) {
    tabs.push(buyVehicleTitle)
  }
  if (canUseMarketplace) {
    tabs.push(sellVehicleTitle)
  }
  return tabs
})

const props = defineProps({
  screenTag: {
    type: String,
    default: "",
  },
  buyingAvailable: {
    type: String,
    default: "true",
  },
  marketplaceAvailable: {
    type: String,
    default: "true",
  },
  selectedSellerId: {
    type: String,
    default: "",
  },
})

const processTabInput = (event) => {
  if (event.detail.name === "tab_l") {
    selectedTab.value = (selectedTab.value - 1 + tabs.value.length) % tabs.value.length
  } else if (event.detail.name === "tab_r") {
    selectedTab.value = (selectedTab.value + 1) % tabs.value.length
  }
}

const onTabsChange = (tab, old) => {
  const idx = tabs.value.indexOf((tab && tab.heading) ? tab.heading : "")
  if (idx !== -1) selectedTab.value = idx
  if (selectedTab.value === tabs.value.indexOf(buyVehicleTitle)) {
    selectedSellerId.value = ""
  }
}

const headerTitle = computed(() => {
  switch (tabs.value[selectedTab.value]) {
    case buyVehicleTitle:
      return "Buy Vehicles"
    case sellVehicleTitle:
      return "Sell Vehicles"
    default:
      return "Available Vehicles"
  }
})

const updateRouteScreenTag = () => {
  if (route.name === "career.computer.vehicleShopping.vehicles") return
  const isSelling = selectedTab.value === tabs.value.indexOf(sellVehicleTitle)
  const screenTag = isSelling ? "marketplace" : "buying"
  const q = { ...route.query }
  router.replace({
    name: "career.computer.vehicleShopping",
    params: {
      screenTag,
      buyingAvailable: props.buyingAvailable,
      marketplaceAvailable: props.marketplaceAvailable,
      selectedSellerId: selectedSellerId.value,
    },
    query: q,
  })
}

watch(selectedTab, () => {
  updateRouteScreenTag()
})

const setSelectedSellerId = (sellerId) => {
  selectedSellerId.value = sellerId
  vehicleShoppingStore.setSelectedSellerId(selectedSellerId.value)
}


const start = () => {
  nextTick(async () => {
    if (racingTeamBizId.value) {
      try {
        sessionStorage.setItem("rtVehicleShop", racingTeamBizId.value)
      } catch (e) {}
    } else {
      try {
        sessionStorage.removeItem("rtVehicleShop")
      } catch (e2) {}
    }
    if (route.query.rtBiz !== undefined && route.query.rtBiz !== null && String(route.query.rtBiz) !== "") {
      try {
        await lua.career_modules_vehicleShopping.setRtBiz(String(route.query.rtBiz))
      } catch (_e) {}
    }
    await vehicleShoppingStore.requestVehicleShoppingData()
    loaded.value = true
    if (vehicleShoppingStore.vehicleShoppingData.currentSeller) {
      setSelectedSellerId(vehicleShoppingStore.vehicleShoppingData.currentSeller)
    } else {
      setSelectedSellerId(vehicleShoppingStore.vehicleShoppingData.selectedSellerId || props.selectedSellerId)
    }

    const screenTag = props.screenTag || vehicleShoppingStore.vehicleShoppingData.screenTag || ""
    if (screenTag == "buying") {
      selectedTab.value = tabs.value.indexOf(buyVehicleTitle)
    } else if (screenTag == "marketplace") {
      selectedTab.value = tabs.value.indexOf(sellVehicleTitle)
    } else {
      selectedTab.value = 0
    }
    updateRouteScreenTag()
  })
}

const kill = async () => {
  const name = route.name
  if (name === "career.computer.vehicleShopping" || (typeof name === "string" && name.startsWith("career.computer.vehicleShopping."))) return
  await lua.career_modules_vehicleShopping.onShoppingMenuClosed()
  vehicleShoppingStore.$dispose()
}

const close = () => {
  lua.extensions.ui_router.back()
}

onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.active-tab {
  background-color: var(--bng-accents);
  color: white;
}

.flex-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  max-width: 80rem;
}

.tabs {
  flex-shrink: 0;
}

.content {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.content :deep(.bng-tabs) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  --tab-bg: var(--bng-black-o8, 0.5);
  --tab-content-bg: var(--bng-black-o8, 0.5);
  --tab-list-corners: var(--bng-corners-2);
  --tab-content-corners: var(--bng-corners-2);
  .tab-list {
    >* {
      flex: 1 auto;
      max-width: none;
      background-color: rgba(var(--bng-cool-gray-400-rgb), 0.1);
    }
  }
}

.content :deep(.tab-container) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.content :deep(.tab-content) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.buying-tab-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  :deep(.bng-card) {
    --bg-opacity: 0.0;
  }
}

.marketplace-tab-content {
  padding: 0.5em;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
}

/* Hide tab list when there's only one tab */
:deep(.single-tab .tab-list) {
  display: none;
}

</style>
