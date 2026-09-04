<template>
  <PhoneWrapper :app-name="phoneAppBarTitle">
    <template v-if="hasBusiness && !loading" #header>
      <PhoneRacingTeamTabBar
        :active-tab="activePhoneScreen"
        :tabs="phoneNavTabs"
        @select="navigateToScreen"
      />
    </template>

    <div class="phone-racing-team" :class="{ 'phone-racing-team--home': activePhoneScreen === 'menu' }">
      <div v-if="loading" class="loading-state">
        <div class="loading-spinner"></div>
        <span>Loading...</span>
      </div>

      <div v-else-if="!hasBusiness" class="error-state">
        <span>{{ skillLockedMessage }}</span>
        <button type="button" class="btn btn-secondary" data-focusable @click="loadingData" @mousedown.stop>
          Retry
        </button>
      </div>

      <template v-else>
        <div class="phone-racing-team-panel">
          <PhoneRacingTeamHome
            v-if="activePhoneScreen === 'menu'"
            @navigate="navigateToScreen"
          />

          <BusinessRacingTab v-else-if="activePhoneScreen === 'races'" layout="phone" />
          <BusinessDriversTab v-else-if="activePhoneScreen === 'drivers'" layout="phone" />
          <div v-else-if="activePhoneScreen === 'vehicles'" class="phone-fleet">
            <p v-if="fleetVehicles.length === 0" class="phone-fleet__empty">No vehicles in garage.</p>
            <ul v-else class="phone-fleet__list">
              <li v-for="(v, idx) in fleetVehicles" :key="fleetRowKey(v, idx)" class="phone-fleet__item">
                <article class="phone-fleet-card" @click.stop @mousedown.stop>
                  <div class="phone-fleet-card__media">
                    <img class="phone-fleet-card__img" :src="fleetCardImage(v)" :alt="fleetCardName(v)" />
                    <div v-if="isDeliveryPending(v)" class="phone-fleet-card__media-overlay">Delivering</div>
                  </div>
                  <div class="phone-fleet-card__content">
                    <h3 class="phone-fleet-card__title">{{ fleetCardName(v) }}</h3>
                    <div
                      v-if="fleetClassBadge(v) || fleetPwBucketLabel(v)"
                      class="phone-fleet-card__class-strip"
                    >
                      <span v-if="fleetClassBadge(v)" class="phone-fleet-class-badge">{{ fleetClassBadge(v) }}</span>
                      <span v-if="fleetPwBucketLabel(v)" class="phone-fleet-class-range">{{ fleetPwBucketLabel(v) }}</span>
                    </div>
                    <p
                      v-if="fleetEffectiveHpDisplay(v) != null || fleetEffectivePwDisplay(v) != null"
                      class="phone-fleet-card__meta"
                    >
                      <template v-if="fleetEffectiveHpDisplay(v) != null">{{ fleetEffectiveHpDisplay(v) }} HP</template>
                      <template v-if="fleetEffectiveHpDisplay(v) != null && fleetEffectivePwDisplay(v) != null"> · </template>
                      <template v-if="fleetEffectivePwDisplay(v) != null">{{ fleetEffectivePwDisplay(v) }} hp/kg</template>
                    </p>
                    <p class="phone-fleet-card__meta">
                      Book {{ formatMoney(v.vehicleValue) }} · Sale {{ formatMoney(v.sellValue) }}
                    </p>
                    <div class="phone-fleet-card__actions">
                      <button
                        type="button"
                        class="btn btn-secondary"
                        data-focusable
                        :disabled="isDeliveryPending(v)"
                        :title="isDeliveryPending(v) ? 'Vehicle is still delivering' : undefined"
                        @click.stop="openSellModal(v)"
                        @mousedown.stop
                      >
                        Sell
                      </button>
                    </div>
                  </div>
                </article>
              </li>
            </ul>
          </div>
        </div>
      </template>
    </div>

    <Teleport to="body">
      <div
        v-if="showSellModal"
        class="phone-fleet-modal-overlay"
        @click.self.stop="cancelSell"
        @mousedown.self.stop="cancelSell"
      >
        <div class="phone-fleet-modal" @click.stop @mousedown.stop>
          <h2>Sell vehicle</h2>
          <p>
            Sell <strong>{{ fleetCardName(vehicleToSell) }}</strong> for
            <strong>{{ formatMoney(confirmSellAmount) }}</strong>? It will be removed from your garage.
          </p>
          <p v-if="sellError" class="phone-fleet-modal__error">{{ sellError }}</p>
          <div class="phone-fleet-modal__actions">
            <button type="button" class="btn btn-secondary" data-focusable @click.stop="cancelSell" @mousedown.stop>
              Cancel
            </button>
            <button type="button" class="btn btn-danger" data-focusable @click.stop="confirmSell" @mousedown.stop>
              Yes, sell
            </button>
          </div>
        </div>
      </div>
    </Teleport>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, provide } from "vue"
import PhoneWrapper from "./PhoneWrapper.vue"
import { lua } from "@/bridge"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import PhoneRacingTeamHome from "../components/phone/PhoneRacingTeamHome.vue"
import PhoneRacingTeamTabBar from "../components/phone/PhoneRacingTeamTabBar.vue"
import BusinessRacingTab from "../components/businessComputer/BusinessRacingTab.vue"
import BusinessDriversTab from "../components/businessComputer/BusinessDriversTab.vue"
import { formatSanctionedClassCompact, pwBucketX1000 } from "../utils/sanctionedClassFormat"
import { DEFAULT_SKILL_LOCKED_MESSAGE } from "../utils/phoneAppRegistry"

const store = useBusinessComputerStore()
const skillLockedMessage = DEFAULT_SKILL_LOCKED_MESSAGE
const moneyFormat = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 })

const loading = ref(true)
const hasBusiness = ref(false)
const activePhoneScreen = ref("menu")

provide("controllerNav", {
  pushModal: () => {},
  removeModal: () => {}
})

const phoneNavTabs = [
  { id: "menu", label: "Home" },
  { id: "drivers", label: "Drivers" },
  { id: "vehicles", label: "Vehicles" },
  { id: "races", label: "Races" }
]

const phoneAppBarTitle = computed(() => {
  if (activePhoneScreen.value === "menu") return "Racing Team"
  return phoneNavTabs.find((t) => t.id === activePhoneScreen.value)?.label ?? "Racing Team"
})

const fleetVehicles = computed(() => {
  const v = store.vehicles
  return Array.isArray(v) ? v.filter(Boolean) : []
})

const showSellModal = ref(false)
const vehicleToSell = ref(null)
const sellError = ref("")

const confirmSellAmount = computed(() => {
  const v = vehicleToSell.value
  if (!v || v.sellValue === undefined || v.sellValue === null) return 0
  return v.sellValue
})

function fleetRowKey(v, idx) {
  const id = v?.vehicleId ?? v?.id
  if (id !== undefined && id !== null && id !== "") return String(id)
  return `vehicle-${idx}`
}

function fleetCardName(v) {
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
}

function fleetCardImage(v) {
  const src = v?.vehicleImage
  if (typeof src === "string" && src.length > 0) return src
  return "/ui/images/appDefault.png"
}

function fleetEffectiveHpDisplay(v) {
  const n = Number(v?.fleetEffectiveHp)
  if (!Number.isFinite(n) || n <= 0) return null
  return Math.round(n)
}

function fleetEffectivePwDisplay(v) {
  const n = Number(v?.fleetEffectivePw)
  if (!Number.isFinite(n) || n <= 0) return null
  return (Math.round(n * 100) / 100).toFixed(2)
}

function fleetClassBadge(v) {
  const badge = formatSanctionedClassCompact(
    v?.fleetSanctionedClassLabel,
    v?.fleetSanctionedClassBranch || v?.fleetSanctionedClassLabel
  )
  if (badge) return badge
  if (typeof v?.fleetClassStatusMessage === "string" && v.fleetClassStatusMessage.trim()) {
    return v.fleetClassStatusMessage.trim()
  }
  return ""
}

function fleetPwBucketLabel(v) {
  const branch = String(v?.fleetSanctionedClassLabel || v?.fleetSanctionedClassBranch || "").toLowerCase()
  if (branch.includes("open")) return "500+"
  const bucket = pwBucketX1000(v?.fleetEffectivePw)
  return bucket != null ? String(bucket) : ""
}

function formatMoney(value) {
  const n = Number(value)
  return moneyFormat.format(Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0)
}

function isDeliveryPending(vehicle) {
  return vehicle?.deliveryPending === true
}

function openSellModal(vehicle) {
  if (!vehicle || isDeliveryPending(vehicle)) return
  vehicleToSell.value = vehicle
  sellError.value = ""
  showSellModal.value = true
}

function cancelSell() {
  showSellModal.value = false
  vehicleToSell.value = null
  sellError.value = ""
}

async function confirmSell() {
  const v = vehicleToSell.value
  if (!v) return
  const vid = v.vehicleId ?? v.id
  if (vid === undefined || vid === null || vid === "") return
  sellError.value = ""
  try {
    const ok = await store.sellVehicle(vid)
    if (ok) {
      cancelSell()
    } else {
      sellError.value = "Could not sell this vehicle."
    }
  } catch (e) {
    sellError.value = "Could not sell this vehicle."
  }
}

const loadingData = async () => {
  hasBusiness.value = false
  loading.value = true
  try {
    const isCareerActive = await lua.career_career.isActive()
    if (!isCareerActive) return

    const purchased = await lua.career_modules_business_businessManager.getPurchasedBusinesses("racingTeam")
    if (!purchased) return

    let targetBusinessId = null
    for (const [id, owned] of Object.entries(purchased)) {
      if (!owned) continue
      const level = await lua.career_modules_business_businessSkillTree.getNodeProgress(
        id,
        "team-operations",
        "shop-app"
      )
      if (level && level > 0) {
        targetBusinessId = id
        break
      }
    }

    if (targetBusinessId) {
      await store.loadBusinessData("racingTeam", targetBusinessId)
      hasBusiness.value = true
    }
  } catch (error) {
    hasBusiness.value = false
  } finally {
    loading.value = false
  }
}

const navigateToScreen = async (screen) => {
  activePhoneScreen.value = screen
  if (screen === "menu" && store.businessId && store.businessType) {
    await store.loadBusinessData(store.businessType, store.businessId)
  }
}

onMounted(() => {
  loadingData()
})

onUnmounted(() => {
  store.onMenuClosed()
})
</script>

<style scoped lang="scss">
.phone-racing-team {
  height: 100%;
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  background: rgba(12, 12, 12, 0.98);
  padding: 0.55em 0.55em 0.85em;
  overflow: hidden;
  box-sizing: border-box;

  &.phone-racing-team--home {
    gap: 0.35em;
    padding-bottom: 0.85em;
  }
}

.phone-racing-team-panel {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;

  :deep(.phone-home) {
    flex: 1;
    min-height: 0;
  }
}

.loading-state,
.error-state {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.8em;
  color: rgba(255, 255, 255, 0.6);
  text-align: center;
}

.loading-spinner {
  width: 28px;
  height: 28px;
  border: 3px solid rgba(255, 255, 255, 0.12);
  border-top-color: #f54900;
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
}


.btn {
  padding: 0.55em 1.25em;
  border-radius: 8px;
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  border: none;
  transition: background 0.15s, opacity 0.15s;
}

.btn-secondary {
  background: rgba(40, 52, 64, 0.95);
  color: rgba(255, 255, 255, 0.92);
  border: 1px solid rgba(245, 73, 0, 0.35);
  &:hover:not(:disabled) {
    border-color: rgba(245, 73, 0, 0.55);
    background: rgba(50, 64, 78, 0.98);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.btn-danger {
  background: rgba(220, 53, 69, 0.9);
  color: #fff;
  &:hover:not(:disabled) {
    background: rgba(236, 74, 88, 1);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.phone-fleet {
  flex: 1;
  min-height: 0;
  min-width: 0;
  overflow-x: hidden;
  overflow-y: auto;
}

.phone-fleet__empty {
  margin: 0.5em 0 0;
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.9em;
  text-align: center;
}

.phone-fleet__list {
  margin: 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.65em;
}

.phone-fleet__item {
  min-width: 0;
}

.phone-fleet-card {
  display: flex;
  flex-direction: column;
  overflow: hidden;
  border-radius: 0.75em;
  background: rgba(20, 28, 36, 0.88);
  border: 1px solid rgba(245, 73, 0, 0.22);
  min-width: 0;
}

.phone-fleet-card__media {
  position: relative;
  width: 100%;
  height: 8.5em;
  flex-shrink: 0;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.35);
}

.phone-fleet-card__img {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
  object-position: center;
}

.phone-fleet-card__media-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.65);
  font-size: 0.8em;
  font-weight: 700;
  color: rgba(255, 200, 120, 0.98);
}

.phone-fleet-card__content {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
  padding: 0.65em 0.75em 0.75em;
}

.phone-fleet-card__title {
  margin: 0;
  font-size: 0.95em;
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
  min-width: 0;
}

.phone-fleet-card__class-strip {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45em 0.65em;
}

.phone-fleet-class-badge {
  padding: 0.3em 0.55em;
  border-radius: 0.45em;
  background: rgba(245, 73, 0, 0.18);
  border: 1px solid rgba(245, 73, 0, 0.32);
  color: rgba(255, 200, 160, 0.95);
  font-size: 0.72em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.phone-fleet-class-range {
  font-size: 0.8em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.72);
}

.phone-fleet-card__meta {
  margin: 0;
  font-size: 0.78em;
  line-height: 1.35;
  color: rgba(255, 255, 255, 0.55);
}

.phone-fleet-card__actions {
  display: flex;
  width: 100%;
  margin-top: 0.15em;
}

.phone-fleet-card__actions .btn {
  flex: 1 1 0;
  min-width: 0;
  padding: 0.5em 0.75em;
  border-radius: 999px;
  font-size: 0.82em;
  font-weight: 700;
}

.phone-fleet-modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 14000;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.72);
  backdrop-filter: blur(4px);
}

.phone-fleet-modal {
  width: min(20em, 92vw);
  margin: 1em;
  padding: 1.25em 1.35em;
  border-radius: 0.5em;
  background: rgba(15, 15, 15, 0.98);
  border: 2px solid rgba(245, 73, 0, 0.6);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.55);
  color: #fff;

  h2 {
    margin: 0 0 0.65em;
    font-size: 1.15em;
    font-weight: 600;
  }

  p {
    margin: 0 0 1em;
    font-size: 0.88em;
    line-height: 1.45;
    color: rgba(255, 255, 255, 0.85);
  }
}

.phone-fleet-modal__error {
  margin: 0.5em 0 0;
  color: #f87171;
  font-size: 0.9em;
}

.phone-fleet-modal__actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5em;
}

@keyframes spin { to { transform: rotate(360deg); } }
</style>
