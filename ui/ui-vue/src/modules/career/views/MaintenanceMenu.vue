<template>
  <ComputerWrapper :title="uiData.facilityName || 'Maintenance'" @back="confirmCancel">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'career-maintenance' }"
      class="maintenance-panel"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      :active="isMaintenanceActive"
      heading="Maintenance"
      heading-hint-start-icon="arrowLargeRight"
      heading-hint-start-binding-event="context"
    >
      <div class="maintenance-body">
        <div v-if="vehicleName" class="vehicle-header">{{ vehicleName }}</div>

        <div v-if="errorMessage" class="error-banner">
          <BngIcon :type="icons.warning" />
          <span>{{ errorMessage }}</span>
        </div>

        <div v-if="loading" class="loading-copy">Loading maintenance data...</div>

        <div v-else class="maintenance-list" v-bng-ui-nav-scroll>
          <Accordion>
            <AccordionItem
              v-for="category in uiData.categories || []"
              :key="category.name"
              :expanded="isExpanded(category.name)"
              navigable
              expand-hint-inline
              @expanded="val => setExpanded(category.name, val)"
            >
              <template #caption>
                <div class="item-caption">
                  <span class="item-name">{{ category.label }}</span>
                  <span class="item-meta">{{ formatMiles(category.avgMiles) }}</span>
                </div>
              </template>
              <template #controls>
                <span class="item-status" :class="categorySummary(category).tone">
                  {{ categorySummary(category).text }}
                </span>
              </template>

              <div class="item-list">
                <div
                  v-for="row in category.rows || []"
                  :key="`${row.category}:${row.item}`"
                  class="service-row"
                >
                  <div class="service-copy">
                    <span class="item-name">{{ row.label }}</span>
                    <span class="item-status" :class="rowStatusClass(row)">
                      {{ rowStatusText(row) }}
                    </span>
                  </div>
                  <div class="item-actions">
                    <BngButton :disabled="isBusy(row, 'check')" @click="runCheck(row)">
                      Check
                    </BngButton>
                    <BngButton
                      :accent="serviceButtonAccent(row)"
                      :icon="isServiceInCart(row) ? icons.undo : ''"
                      :disabled="isServiceCovered(row) || checkoutBusy"
                      @click="toggleService(row)"
                    >
                      <span>{{ serviceButtonLabel(row) }}</span>
                      <span v-if="!isServiceInCart(row) && !isServiceCovered(row)" class="action-price">
                        {{ formatServicePrice(row.servicePrice) }}
                      </span>
                    </BngButton>
                  </div>
                </div>
              </div>
            </AccordionItem>

            <AccordionItem
              :expanded="isExpanded('tires')"
              navigable
              expand-hint-inline
              @expanded="val => setExpanded('tires', val)"
            >
              <template #caption>
                <div class="item-caption">
                  <span class="item-name">Tires</span>
                  <span v-if="uiData.tireShop?.provider" class="item-meta">
                    {{ uiData.tireShop.provider.name }}
                  </span>
                </div>
              </template>
              <template #controls>
                <span class="item-status" :class="tireSummary.tone">{{ tireSummary.text }}</span>
              </template>

              <div class="item-list tire-content">
                <div v-if="!uiData.tireShop?.available" class="tire-message">
                  {{ uiData.tireShop?.message || "Tire service is unavailable." }}
                </div>

                <template v-else-if="!uiData.tireShop.inspected">
                  <div class="item-actions single">
                    <BngButton
                      :accent="ACCENTS.primary"
                      :disabled="busyActionKey === 'tires:check'"
                      @click="runTireCheck"
                    >
                      Check All Tires — Free
                    </BngButton>
                  </div>
                </template>

                <template v-else>
                  <div
                    v-for="axle in uiData.tireShop.axles || []"
                    :key="axle.id"
                    class="service-row"
                  >
                    <div class="service-copy">
                      <div class="item-caption">
                        <span class="item-name">{{ axle.label }}</span>
                        <span class="item-meta">{{ axle.tireName }} · {{ axle.tireCount }}</span>
                      </div>
                      <span class="item-status" :class="axle.flat ? 'bad' : axleStatusClass(axle.remainingPercent)">
                        {{ axle.flat ? "Flat" : `${axle.remainingPercent}%` }}
                      </span>
                    </div>
                    <div class="tire-wheels">
                      {{ (axle.wheelStates || []).map(wheel => `${wheel.name}: ${wheel.flat ? "FLAT" : `${wheel.remainingPercent}%`}`).join(" · ") }}
                    </div>
                    <div class="item-actions single">
                      <BngButton
                        :accent="isTireInCart(axle.id) ? ACCENTS.attention : ACCENTS.outlined"
                        :icon="isTireInCart(axle.id) ? icons.undo : ''"
                        :disabled="checkoutBusy"
                        @click="toggleTire(axle.id)"
                      >
                        <span>{{ isTireInCart(axle.id) ? "Remove" : "Replace" }}</span>
                        <span v-if="!isTireInCart(axle.id)" class="action-price">
                          {{ formatServicePrice(axle.subtotal) }}
                        </span>
                      </BngButton>
                    </div>
                  </div>

                  <div class="item-actions single tire-all">
                    <BngButton
                      :accent="allTiresInCart ? ACCENTS.attention : ACCENTS.primary"
                      :icon="allTiresInCart ? icons.undo : ''"
                      :disabled="checkoutBusy || !(uiData.tireShop.axles || []).length"
                      @click="toggleAllTires"
                    >
                      {{ allTiresInCart ? "Remove All Tires" : `Replace All — ${formatServicePrice(uiData.tireShop.replaceAllSubtotal)}` }}
                    </BngButton>
                  </div>
                </template>
              </div>
            </AccordionItem>
          </Accordion>
        </div>
      </div>
    </ComputerPanel>

    <template #side>
      <ShoppingCart
        v-bng-scoped-nav="{ scopeId: 'career-maintenance-cart' }"
        :active="isCartActive"
        :cart-data="cartData"
        :player-money="playerMoney"
        confirm-button-text="Confirm"
        v-bng-on-ui-nav:context="switchToMaintenance"
        @apply="applyCart"
        @cancel="confirmCancel"
        @remove-item="removeCartItem"
      />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { computed, onMounted, reactive, ref } from "vue"
import { lua } from "@/bridge"
import { installLuaBridgeFallbacks, callModLua } from "../utils/installLuaBridgeFallbacks"

installLuaBridgeFallbacks()
import { ACCENTS, BngButton, BngIcon, icons } from "@/common/components/base"
import { Accordion, AccordionItem } from "@/common/components/utility"
import { vBngBlur, vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { useScopedNav } from "@/services/scopedNav/api"
import { openConfirmation } from "@/services/popup"
import { useUINavBlocker } from "@/services/uiNavTracker"
import ComputerPanel from "../components/ComputerPanel.vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import ShoppingCart from "../components/ShoppingCart.vue"

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const { switchScope, current } = useScopedNav()
const isCartActive = computed(() => current.value?.id === "career-maintenance-cart")
const isMaintenanceActive = computed(() => current.value?.id === "career-maintenance")
const switchToCart = () => switchScope("career-maintenance-cart")
const switchToMaintenance = () => switchScope("career-maintenance")

const CANCEL_MESSAGE = "Leave maintenance? Your cart will be cleared."
const CONFIRM_BUTTONS = [
  { label: "Yes", value: true },
  { label: "No", value: false, extras: { accent: ACCENTS.secondary } },
]

const uiData = ref({
  facilityName: "Maintenance",
  vehicle: null,
  categories: [],
  tireShop: null,
  playerMoney: 0,
})
const loading = ref(true)
const errorMessage = ref("")
const busyActionKey = ref("")
const checkoutBusy = ref(false)
const expandedKeys = reactive({})
const cartServices = ref([])
const cartTireAxles = ref([])

let refreshing = false

const parseMoney = value => {
  if (value && typeof value === "object") value = value.value
  const amount = Number(value)
  return Number.isFinite(amount) ? amount : null
}

const requestData = async () => {
  if (refreshing) return
  refreshing = true
  try {
    const result = await lua.career_modules_maintenanceComputer.getMaintenanceUiData()
    if (result?.errorMessage) {
      errorMessage.value = result.debugError ? `${result.errorMessage} ${result.debugError}` : result.errorMessage
      return
    }
    if (!result?.enabled || !result?.vehicle) {
      await close()
      return
    }
    let playerMoneyValue = parseMoney(result.playerMoney)
    if (playerMoneyValue == null) {
      try {
        playerMoneyValue = parseMoney(await lua.career_modules_playerAttributes.getAttributeValue("money"))
      } catch (_) {
        playerMoneyValue = null
      }
    }
    uiData.value = { ...result, playerMoney: playerMoneyValue }
    pruneCart()
    errorMessage.value = ""
  } catch (error) {
    errorMessage.value = error?.message || "Failed to load maintenance data."
  } finally {
    loading.value = false
    refreshing = false
  }
}

const vehicleName = computed(() => uiData.value.vehicle?.niceName || uiData.value.vehicle?.name || "")
const playerMoney = computed(() => parseMoney(uiData.value.playerMoney) ?? undefined)

const formatMiles = miles => `${Math.round(miles || 0).toLocaleString()} mi`

const formatServicePrice = price => `$${Math.max(0, Math.round(Number(price) || 0)).toLocaleString()}`

const isExpanded = key => Boolean(expandedKeys[key])

const setExpanded = (key, val) => {
  expandedKeys[key] = Boolean(val)
}

const statusTone = percent => {
  if (percent == null) return "unknown"
  if (percent <= 25) return "bad"
  if (percent <= 50) return "warn"
  return "ok"
}

const rowStatusText = row => (row.isRevealed ? `${row.revealedPercent}%` : "Unknown")

const rowStatusClass = row => (row.isRevealed ? statusTone(row.revealedPercent) : "unknown")

const categorySummary = category => {
  const rows = category.rows || []
  const revealed = rows.filter(row => row.isRevealed)
  if (!revealed.length) return { text: "Not checked", tone: "unknown" }
  const worst = Math.min(...revealed.map(row => Number(row.revealedPercent) || 0))
  const unknownCount = rows.length - revealed.length
  return {
    text: unknownCount ? `${worst}% · ${unknownCount} unknown` : `${worst}%`,
    tone: statusTone(worst),
  }
}

const axleStatusClass = percent => statusTone(percent)

const tireSummary = computed(() => {
  const shop = uiData.value.tireShop
  if (!shop?.available) return { text: "Unavailable", tone: "unknown" }
  if (!shop.inspected) return { text: "Not checked", tone: "unknown" }
  const axles = shop.axles || []
  if (axles.some(axle => axle.flat)) return { text: "Flat", tone: "bad" }
  if (!axles.length) return { text: "Checked", tone: "ok" }
  const worst = Math.min(...axles.map(axle => Number(axle.remainingPercent) || 0))
  return { text: `${worst}%`, tone: statusTone(worst) }
})

const findRow = (category, item) => {
  for (const cat of uiData.value.categories || []) {
    for (const row of cat.rows || []) {
      if (row.category === category && row.item === item) return row
    }
  }
  return null
}

const findAxle = axleId => (uiData.value.tireShop?.axles || []).find(axle => axle.id === axleId)

const isServiceInCart = row =>
  cartServices.value.some(entry => entry.category === row.category && entry.item === row.item)

const isServiceCovered = row =>
  cartServices.value.some(entry => {
    const cartRow = findRow(entry.category, entry.item)
    return cartRow && cartRow.category === row.category && cartRow.fillsItem === row.item
  })

const isTireInCart = axleId => cartTireAxles.value.includes(axleId)

const allTiresInCart = computed(() => {
  const axles = uiData.value.tireShop?.axles || []
  return axles.length > 0 && axles.every(axle => isTireInCart(axle.id))
})

const serviceButtonAccent = row => {
  if (isServiceCovered(row)) return ACCENTS.outlined
  if (isServiceInCart(row)) return ACCENTS.attention
  return ACCENTS.primary
}

const serviceButtonLabel = row => {
  if (isServiceCovered(row)) return "Included"
  if (isServiceInCart(row)) return "Remove"
  return row.actionLabel
}

const pruneCart = () => {
  cartServices.value = cartServices.value.filter(entry => findRow(entry.category, entry.item))
  cartTireAxles.value = cartTireAxles.value.filter(axleId => Boolean(findAxle(axleId)))
}

const cartHasItems = computed(() => cartData.value.items.length > 0)

const cartData = computed(() => {
  const items = []
  let total = 0

  for (const entry of cartServices.value) {
    const row = findRow(entry.category, entry.item)
    if (!row || isServiceCovered(row)) continue
    const price = Number(row.servicePrice) || 0
    items.push({
      name: `${row.actionLabel} ${row.label}`,
      price,
      removeShow: true,
      kind: "service",
      category: row.category,
      item: row.item,
    })
    total += price
  }

  for (const axleId of cartTireAxles.value) {
    const axle = findAxle(axleId)
    if (!axle) continue
    const price = Number(axle.subtotal) || 0
    items.push({
      name: `Replace ${axle.label} Tires`,
      extraInfo: `${axle.tireName} · ${axle.tireCount} tires`,
      price,
      removeShow: true,
      kind: "tire",
      axleId,
    })
    total += price
  }

  return { items, total, taxes: 0 }
})

const toggleService = row => {
  if (isServiceCovered(row)) return
  if (isServiceInCart(row)) {
    cartServices.value = cartServices.value.filter(
      entry => !(entry.category === row.category && entry.item === row.item)
    )
    return
  }
  if (row.fillsItem) {
    cartServices.value = cartServices.value.filter(
      entry => !(entry.category === row.category && entry.item === row.fillsItem)
    )
  }
  cartServices.value = [...cartServices.value, { category: row.category, item: row.item }]
}

const toggleTire = axleId => {
  if (isTireInCart(axleId)) {
    cartTireAxles.value = cartTireAxles.value.filter(id => id !== axleId)
    return
  }
  cartTireAxles.value = [...cartTireAxles.value, axleId]
}

const toggleAllTires = () => {
  const axles = uiData.value.tireShop?.axles || []
  if (allTiresInCart.value) {
    cartTireAxles.value = []
    return
  }
  cartTireAxles.value = axles.map(axle => axle.id)
}

const removeCartItem = item => {
  if (item.kind === "tire") {
    toggleTire(item.axleId)
    return
  }
  const row = findRow(item.category, item.item)
  if (row) toggleService(row)
}

const makeBusyKey = (row, action) => `${row.category}:${row.item}:${action}`

const isBusy = (row, action) => busyActionKey.value === makeBusyKey(row, action)

const runCheck = async row => {
  busyActionKey.value = makeBusyKey(row, "check")
  try {
    const result = await lua.career_modules_maintenanceComputer.startCheck(
      Number(uiData.value.inventoryId),
      row.category,
      row.item
    )
    if (!result?.ok) {
      errorMessage.value = result?.message || "Unable to complete check."
      return
    }
    await requestData()
  } finally {
    busyActionKey.value = ""
  }
}

const runTireCheck = async () => {
  busyActionKey.value = "tires:check"
  try {
    const result = await lua.career_modules_maintenanceComputer.inspectTires(Number(uiData.value.inventoryId))
    if (!result?.ok) {
      errorMessage.value = result?.message || "Unable to inspect tires."
      return
    }
    await requestData()
  } finally {
    busyActionKey.value = ""
  }
}

const clearCart = () => {
  cartServices.value = []
  cartTireAxles.value = []
}

const applyCart = async () => {
  if (!cartHasItems.value || checkoutBusy.value) return
  checkoutBusy.value = true
  errorMessage.value = "Checking out..."
  try {
    const payload = JSON.stringify({
      services: cartServices.value.map(entry => ({ category: entry.category, item: entry.item })),
      tireAxleIds: [...cartTireAxles.value],
      quoteRevision: uiData.value.tireShop?.quoteRevision || "",
    })
    const result = await Promise.race([
      callModLua("career_modules_maintenanceComputer.checkoutCart", Number(uiData.value.inventoryId), payload),
      new Promise((_, reject) => setTimeout(() => reject(new Error("Checkout timed out.")), 15000)),
    ])
    if ((result && result.ok === false) || result?.staleQuote) {
      errorMessage.value = result?.message || result?.debugError || "Unable to complete checkout."
      if (result?.staleQuote) await requestData()
      return
    }
    errorMessage.value = ""
    clearCart()
    await callModLua("extensions.ui_router.navigate", "career.computer")
  } catch (error) {
    errorMessage.value = error?.message || "Unable to complete checkout."
  } finally {
    checkoutBusy.value = false
  }
}

const close = async () => {
  await callModLua("career_modules_maintenanceComputer.closeMenu")
  await callModLua("extensions.ui_router.navigate", "career.computer")
}

const confirmCancel = async () => {
  if (!cartHasItems.value || await openConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)) {
    clearCart()
    await close()
  }
}

onMounted(async () => {
  await requestData()
})
</script>

<style scoped lang="scss">
.maintenance-panel {
  --bng-card-height: 100%;
  width: 30em;
  height: 100%;
  overflow: hidden;

  &:deep(.panel-content) {
    flex: 1 1 0;
    min-height: 0;
    overflow: hidden;
  }
}

.maintenance-body {
  display: flex;
  flex-direction: column;
  min-height: 0;
  height: 100%;
  overflow: hidden;
  color: white;
}

.vehicle-header {
  flex: 0 0 auto;
  padding: 0.65rem 0.85rem 0.35rem;
  font-size: 0.95rem;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.82);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.loading-copy {
  padding: 1rem 0.85rem;
  color: rgba(255, 255, 255, 0.7);
}

.error-banner {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0.35rem 0.6rem 0;
  padding: 0.6rem 0.75rem;
  border-radius: 0.5rem;
  background: rgba(160, 33, 33, 0.8);
  color: #fff;
}

.maintenance-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0.25rem 0 0.75rem;
}

.item-caption {
  display: flex;
  flex-direction: column;
  min-width: 0;
  gap: 0.05rem;
}

.item-name {
  display: block;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.item-meta {
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.78rem;
  font-weight: 400;
}

.item-status {
  padding-right: 0.35rem;
  font-size: 0.85rem;
  font-weight: 700;
  white-space: nowrap;

  &.ok { color: #9edb8f; }
  &.warn { color: #ebc140; }
  &.bad { color: #ff7777; }
  &.unknown { color: rgba(255, 255, 255, 0.55); font-weight: 600; }
}

.item-list {
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
  padding: 0.25rem 0.15rem 0.45rem;
}

.service-row {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  padding: 0.55rem 0.5rem 0.45rem;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.5rem;
  background: rgba(255, 255, 255, 0.03);
}

.service-copy {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75rem;
}

.item-actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.4rem;
  padding: 0;

  &.single {
    grid-template-columns: 1fr;
  }
}

.item-actions :deep(.bng-button),
.item-actions :deep(button) {
  width: 100%;
}

.action-price {
  margin-left: 0.35rem;
}

.tire-content {
  padding-right: 0.15rem;
}

.tire-message {
  padding: 0.15rem 0.35rem 0.45rem;
  color: rgba(255, 255, 255, 0.7);
  font-size: 0.85rem;
}

.tire-wheels {
  color: rgba(255, 255, 255, 0.7);
  font-size: 0.85rem;
}

.tire-all {
  padding-top: 0.35rem;
}

:deep(.bng-accitem-caption-content) {
  overflow: hidden;
}

:deep(.bng-accitem-caption-controls) {
  overflow: visible;
}
</style>
