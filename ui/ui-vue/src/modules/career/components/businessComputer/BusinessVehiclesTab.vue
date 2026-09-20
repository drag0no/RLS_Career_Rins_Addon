<template>
  <div class="vehicles-tab">
    <div class="tab-header">
      <div class="header-content">
        <div>
          <h2>Vehicles</h2>
          <p>
            {{
              store.businessType === "racingTeam"
                ? "Garage vehicles and shopping"
                : "Garage inventory"
            }}
          </p>
        </div>
        <div
          v-if="store.businessType === 'racingTeam'"
          class="header-actions"
        >
          <button
            type="button"
            class="btn btn-primary header-action-btn"
            data-focusable
            @click.stop="goTeamVehicleShop"
            @mousedown.stop="goTeamVehicleShop"
          >
            Vehicle Shopping
          </button>
        </div>
      </div>
    </div>

    <div v-if="hasVehiclesTabContent" class="jobs-content">
      <div class="job-section">
        <h3>Garage</h3>
        <div class="vehicle-list">
          <article
            v-for="v in fleetVehicles"
            :key="`fleet-${v.vehicleId ?? v.id}`"
            class="vehicle-row"
            :class="{ expanded: isExpanded(v) }"
            @click.stop="interceptEvent"
            @mousedown.stop="interceptEvent"
          >
            <div
              class="vehicle-row__header"
              role="button"
              tabindex="0"
              :aria-expanded="isExpanded(v)"
              data-focusable
              @click.stop="toggleExpanded(v)"
              @mousedown.stop
              @keydown.enter.prevent="toggleExpanded(v)"
              @keydown.space.prevent="toggleExpanded(v)"
            >
              <div class="vehicle-row__identity">
                <div class="vehicle-row__thumb-wrap">
                  <img class="vehicle-row__thumb" :src="fleetCardImage(v)" :alt="fleetCardName(v)" />
                  <div v-if="isDeliveryPending(v)" class="vehicle-row__delivery-overlay">
                    <span>{{ deliveryOverlayText(v) }}</span>
                  </div>
                </div>
                <div class="vehicle-row__copy">
                  <h4>{{ fleetCardName(v) }}</h4>
                  <p v-if="store.businessType === 'racingTeam' && fleetSanctionedClassDisplay(v)" class="vehicle-row__meta vehicle-row__meta--class">
                    <span class="vehicle-row__bracket">{{ fleetSanctionedClassDisplay(v) }}</span>
                  </p>
                  <p
                    v-if="store.businessType === 'racingTeam' && (fleetEffectiveHpDisplay(v) != null || fleetEffectivePwDisplay(v) != null)"
                    class="vehicle-row__meta vehicle-row__meta--hp"
                  >
                    <template v-if="fleetEffectiveHpDisplay(v) != null">{{ fleetEffectiveHpDisplay(v) }} HP</template>
                    <template v-if="fleetEffectiveHpDisplay(v) != null && fleetEffectivePwDisplay(v) != null"> · </template>
                    <template v-if="fleetEffectivePwDisplay(v) != null">{{ fleetEffectivePwDisplay(v) }} hp/kg</template>
                    <span :class="dynoBadgeDisplay(v).class">{{ dynoBadgeDisplay(v).label }}</span>
                  </p>
                  <p v-if="v.vehicleYear && v.vehicleYear !== 'Unknown'" class="vehicle-row__meta">
                    {{ v.vehicleYear }}
                    <span v-if="v.vehicleType && v.vehicleType !== 'Unknown'"> · {{ v.vehicleType }}</span>
                  </p>
                </div>
              </div>
              <div class="vehicle-row__stats">
                <p
                  class="vehicle-row__meta"
                  v-bng-tooltip:top="'Recorded value for this vehicle on the business books.'"
                >
                  Book value: {{ formatMoney(v.vehicleValue) }}
                </p>
                <p
                  class="vehicle-row__meta"
                  v-bng-tooltip:top="'Approximate payout if you sell this vehicle now.'"
                >
                  Est. sale value: {{ formatMoney(v.sellValue) }}
                </p>
              </div>
              <div class="vehicle-row__status">
                <span v-if="isDeliveryPending(v)" class="vehicle-row__badge vehicle-row__badge--delivery">Delivering</span>
                <span v-else-if="isPulledOut(v)" class="vehicle-row__badge">Pulled Out</span>
                <span v-else class="vehicle-row__badge vehicle-row__badge--idle">Stored</span>
                <span v-if="isDeliveryPending(v)" class="vehicle-row__cooldown">
                  {{ deliveryOverlayText(v) }}
                </span>
                <span
                  v-else-if="store.businessType === 'racingTeam' && fleetVehicleCooldownSec(v) > 0"
                  class="vehicle-row__cooldown"
                >
                  Cooling down {{ formatCooldownMSS(fleetVehicleCooldownSec(v)) }}
                </span>
                <svg class="vehicle-row__chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polyline :points="isExpanded(v) ? '18 15 12 9 6 15' : '6 9 12 15 18 9'" />
                </svg>
              </div>
            </div>

            <div v-if="isExpanded(v)" class="vehicle-row__expanded">
              <p v-if="isDeliveryPending(v)" class="vehicle-row__hint">
                Vehicle is not selectable until delivery completes.
              </p>
              <p
                v-if="showLiftSlotsWarning(v)"
                class="vehicle-row__hint vehicle-row__hint--warning"
              >
                {{ liftSlotsWarningText }}
              </p>
              <p
                v-else-if="!isDeliveryPending(v) && !isPulledOut(v)"
                class="vehicle-row__hint"
              >
                Pull out vehicle to work on it
              </p>
              <p v-if="store.businessType === 'racingTeam' && fleetSanctionedClassDisplay(v)" class="vehicle-row__meta vehicle-row__meta--class">
                Class: {{ fleetSanctionedClassDisplay(v) }}
              </p>

              <div class="vehicle-row__actions">
                <button
                  v-if="!isPulledOut(v)"
                  class="btn btn-primary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v) || pullOutBlockedByFleetCooldown(v) || pullOutBlockedByLiftsFull(v)"
                  :title="pullOutDisabledTitle(v)"
                  @click.stop="handlePullOut(v)"
                  @mousedown.stop
                >
                  Pull Out
                </button>
                <button
                  v-if="showLiftSlotsWarning(v) && canUpgradeGarageSlots"
                  type="button"
                  class="btn btn-secondary"
                  data-focusable
                  @click.stop="goToGarageSlotsSkillTree"
                  @mousedown.stop
                >
                  Skill Trees
                </button>
                <button
                  v-if="isPulledOut(v)"
                  class="btn btn-secondary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v)"
                  :title="vehicleDisabledTitle(v)"
                  @click.stop="handlePutAway(v)"
                  @mousedown.stop
                >
                  Put Away
                </button>
                <button
                  class="btn btn-danger"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v)"
                  :title="vehicleDisabledTitle(v)"
                  @click.stop="handleSell(v)"
                  @mousedown.stop
                >
                  Sell
                </button>
              </div>

              <div class="vehicle-row__actions">
                <button
                  class="btn btn-primary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                  :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                  @click.stop="goToVehicleParts(v)"
                  @mousedown.stop
                >
                  Parts
                </button>
                <button
                  class="btn btn-primary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                  :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                  @click.stop="goToVehicleTuning(v)"
                  @mousedown.stop
                >
                  Tuning
                </button>
                <button
                  v-if="store.businessType === 'racingTeam'"
                  class="btn btn-primary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                  :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                  @click.stop="startVehiclePaint(v)"
                  @mousedown.stop
                >
                  Paint
                </button>
                <button
                  v-if="store.isMaintenanceEnabled"
                  class="btn btn-primary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v) || !isPulledOut(v)"
                  :title="vehicleDisabledTitle(v, !isPulledOut(v) ? 'Pull out vehicle to work on it' : '')"
                  @click.stop="openMaintenanceModal(v)"
                  @mousedown.stop
                >
                  Maintain
                </button>
                <button
                  v-if="store.businessType === 'racingTeam' && v.fleetRepairNeeded"
                  class="btn btn-primary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v)"
                  :title="vehicleDisabledTitle(v)"
                  @click.stop="openRepairModal(v)"
                  @mousedown.stop
                >
                  Repair
                </button>
                <button
                  v-if="store.businessType === 'racingTeam' && v.dynoStatus === -1"
                  class="btn btn-secondary"
                  data-focusable
                  :disabled="isVehicleLockedForDelivery(v)"
                  @click.stop="handleAssessVehicle(v)"
                  @mousedown.stop
                >
                  Assess Car (${{ v.assessmentCost || 1200 }})
                </button>
                <button
                  v-else-if="store.businessType === 'racingTeam' && v.dynoStatus === 0"
                  class="btn btn-secondary"
                  data-focusable
                  disabled
                >
                  Assessing... ({{ formatAssessmentTime(v.assessmentRemainingSec) }})
                </button>
              </div>
            </div>
          </article>
        </div>
      </div>
    </div>

    <div v-else class="empty-state">No vehicles available right now</div>

    <BusinessMaintenanceModal
      ref="maintenanceModalComponentRef"
      v-model:open="showMaintenanceModal"
      :vehicle="vehicleToMaintain"
      @close="closeMaintenanceModal"
    />
    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="showRepairModal"
          class="modal-overlay"
          @click.self.stop="cancelRepair"
          @mousedown.self.stop="cancelRepair"
        >
          <div class="modal-content modal-content--repair" ref="repairModalRef">
            <h2>Repair vehicle</h2>
            <p>
              Team insurance covers the repair. Your deductible is
              <strong>{{ formatMoney(confirmRepairDeductible) }}</strong>
              (charged from the business account).
            </p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" data-focusable @click.stop="cancelRepair" @mousedown.stop="cancelRepair">
                Cancel
              </button>
              <button class="btn btn-primary" data-focusable @click.stop="confirmRepair" @mousedown.stop="confirmRepair">
                Pay &amp; repair
              </button>
            </div>
          </div>
        </div>
      </transition>
      <transition name="modal-fade">
        <div
          v-if="showAbandonModal"
          class="modal-overlay"
          @click.self.stop="cancelAbandon"
          @mousedown.self.stop="cancelAbandon"
        >
          <div class="modal-content" ref="abandonModalRef">
            <h2>Sell vehicle</h2>
            <p>
              Are you sure you want to sell this vehicle for
              <strong>{{ formatMoney(confirmSellAmount) }}</strong>? It will be removed from your garage.
            </p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" data-focusable @click.stop="cancelAbandon" @mousedown.stop="cancelAbandon">
                Cancel
              </button>
              <button class="btn btn-danger" data-focusable @click.stop="confirmAbandon" @mousedown.stop="confirmAbandon">
                Yes, sell
              </button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { ref, computed, Teleport, watch, inject, nextTick, onMounted, onUnmounted } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { normalizeId, getDynoStatusBadge } from "../../utils/businessUtils"
import { formatSanctionedClassWithBucket } from "../../utils/sanctionedClassFormat"
import { vBngTooltip } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import BusinessMaintenanceModal from "./BusinessMaintenanceModal.vue"

const store = useBusinessComputerStore()
const bridge = useBridge()
const GARAGE_SLOTS_MAX_LEVEL = 2
const moneyFormat = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 })

const DYNO_CLASS_MAP = {
  "dyno-tag--certified": "vehicle-row__dyno",
  "dyno-tag--assessing": "vehicle-row__dyno-progress",
  "dyno-tag--required": "vehicle-row__dyno-required",
}
const dynoBadgeDisplay = (v) => {
  const badge = getDynoStatusBadge(v?.dynoStatus)
  return { label: badge.label, class: DYNO_CLASS_MAP[badge.badgeClass] || "vehicle-row__dyno" }
}

const fleetVehicles = computed(() => {
  const v = store.vehicles
  return Array.isArray(v) ? v.filter(Boolean) : []
})

const hasVehiclesTabContent = computed(() => fleetVehicles.value.length > 0)

/** Wall-clock countdown per inventory id; keys match Lua racingTeamFleetCooldowns (tostring(vehicleId)). */
const fleetCooldownAnchors = ref({})
const fleetCooldownTick = ref(0)
let fleetCooldownTickTimer = null
const pendingDeliveryRefreshInFlight = ref(false)
const pendingDeliveryLastRefreshMs = ref(0)

function mapLookupFleetCooldown(map, rawId) {
  if (!map || rawId === undefined || rawId === null || rawId === "") {
    return 0
  }
  const keys = new Set([String(rawId)])
  const norm = normalizeId(rawId)
  if (norm !== null) {
    keys.add(String(norm))
  }
  for (const k of keys) {
    const val = map[k]
    if (val !== undefined && val !== null && Number.isFinite(Number(val))) {
      return Number(val)
    }
  }
  return 0
}

function fleetAnchorKey(vehicle) {
  const raw = vehicle?.vehicleId
  if (raw === undefined || raw === null || raw === "") {
    return ""
  }
  const norm = normalizeId(raw)
  return String(norm ?? raw)
}

function syncFleetCooldownAnchorsFromStore() {
  const now = Date.now()
  if (store.businessType !== "racingTeam") {
    fleetCooldownAnchors.value = {}
    return
  }
  const map = store.businessData?.racingTeamFleetCooldowns
  const next = {}
  for (const veh of fleetVehicles.value) {
    const key = fleetAnchorKey(veh)
    if (!key) {
      continue
    }
    const sec = mapLookupFleetCooldown(map, veh?.vehicleId)
    next[key] = { startSec: Math.max(0, Math.floor(sec || 0)), startMs: now }
  }
  fleetCooldownAnchors.value = next
}

watch(
  [
    () => store.businessType,
    () => store.businessData?.racingTeamFleetCooldowns,
    () => fleetVehicles.value,
  ],
  () => {
    syncFleetCooldownAnchorsFromStore()
  },
  { deep: true, immediate: true }
)

function formatCooldownMSS(totalSec) {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
  }
  return `${m}:${String(r).padStart(2, "0")}`
}

function fleetVehicleCooldownSec(vehicle) {
  void fleetCooldownTick.value
  if (store.businessType !== "racingTeam") {
    return 0
  }
  const key = fleetAnchorKey(vehicle)
  const anchor = key ? fleetCooldownAnchors.value[key] : null
  if (anchor && anchor.startSec > 0) {
    const elapsed = Math.floor((Date.now() - anchor.startMs) / 1000)
    return Math.max(0, anchor.startSec - elapsed)
  }
  return Math.max(0, Number(vehicle?.cooldownSec) || 0)
}

function isDeliveryPending(vehicle) {
  return vehicle?.deliveryPending === true
}

function deliveryPendingSec(vehicle) {
  if (!isDeliveryPending(vehicle)) {
    return 0
  }
  void fleetCooldownTick.value
  const dueEpoch = Number(vehicle?.deliveryDueEpoch)
  if (Number.isFinite(dueEpoch) && dueEpoch > 0) {
    return Math.max(0, Math.floor(dueEpoch - Date.now() / 1000))
  }
  const start = Number(vehicle?.deliverySecondsRemaining)
  if (!Number.isFinite(start) || start <= 0) {
    return 0
  }
  return Math.max(0, Math.floor(start))
}

function deliveryOverlayText(vehicle) {
  if (!isDeliveryPending(vehicle)) {
    return ""
  }
  if (vehicle?.deliveryMode === "drive") {
    return "Drive to team garage"
  }
  const sec = deliveryPendingSec(vehicle)
  return sec > 0 ? `Arrives in ${formatCooldownMSS(sec)}` : "Finalizing delivery"
}

function isVehicleLockedForDelivery(vehicle) {
  return isDeliveryPending(vehicle)
}

const hasPendingDeliveries = computed(() => fleetVehicles.value.some((v) => isDeliveryPending(v)))

async function refreshPendingDeliveriesIfNeeded(nowMs) {
  if (store.businessType !== "racingTeam" || !hasPendingDeliveries.value) {
    return
  }
  if (pendingDeliveryRefreshInFlight.value) {
    return
  }
  // Refresh every 2s while pending cards exist so delivery completion clears without tab switches.
  if (nowMs - pendingDeliveryLastRefreshMs.value < 2000) {
    return
  }
  const businessType = store.businessType
  const businessId = store.businessId
  if (!businessType || businessId === undefined || businessId === null || businessId === "") {
    return
  }
  pendingDeliveryRefreshInFlight.value = true
  pendingDeliveryLastRefreshMs.value = nowMs
  try {
    await store.loadBusinessData(businessType, businessId)
  } finally {
    pendingDeliveryRefreshInFlight.value = false
  }
}

function pullOutBlockedByFleetCooldown(_vehicle) {
  // Fleet post-race cooldown must not block pull-out / garage work.
  return false
}

function pullOutCooldownTitle(vehicle) {
  return `Vehicle cooling down (${formatCooldownMSS(fleetVehicleCooldownSec(vehicle))} remaining)`
}

function vehicleDisabledTitle(vehicle, fallback = "") {
  if (isVehicleLockedForDelivery(vehicle)) {
    return "Delivery in progress."
  }
  return fallback
}

function fleetCardName(v) {
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
}

/** Effective fleet HP from Lua (dyno/catalog); null if unknown. */
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

/** Sanctioned P/W sub-bracket label from Lua (matches race offers). */
function fleetSanctionedClassDisplay(v) {
  return formatSanctionedClassWithBucket(v?.fleetSanctionedClassLabel, v?.fleetEffectivePw)
    || (typeof v?.fleetClassStatusMessage === "string" ? v.fleetClassStatusMessage : "")
}

function fleetCardImage(v) {
  const src = v?.vehicleImage
  if (typeof src === "string" && src.length > 0) return src
  return "/ui/images/appDefault.png"
}

function formatMoney(value) {
  const n = Number(value)
  return moneyFormat.format(Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0)
}

async function goTeamVehicleShop() {
  const id = store.businessId
  if (id === null || id === undefined || id === "") return
  await lua.career_modules_vehicleShopping.setRtBiz(String(id))
  await lua.extensions.ui_router.navigate("career.computer.vehicleShopping", {
    screenTag: "buying",
    buyingAvailable: "true",
    marketplaceAvailable: "true",
    selectedSellerId: "",
  })
}

const controllerNav = inject("controllerNav", null)
const abandonModalRef = ref(null)
const repairModalRef = ref(null)
const maintenanceModalComponentRef = ref(null)
const showAbandonModal = ref(false)
const showRepairModal = ref(false)
const showMaintenanceModal = ref(false)
const vehicleToSell = ref(null)
const vehicleToRepair = ref(null)
const vehicleToMaintain = ref(null)
const expandedVehicleId = ref(null)
const interceptEvent = () => {}
const confirmSellAmount = computed(() => {
  const v = vehicleToSell.value
  if (!v || v.sellValue === undefined || v.sellValue === null) return 0
  return v.sellValue
})

const confirmRepairDeductible = computed(() => {
  const v = vehicleToRepair.value
  const n = Number(v?.fleetRepairDeductible)
  return Number.isFinite(n) && n >= 0 ? n : 750
})

const pulledOutVehicleIds = computed(() => {
  const list = Array.isArray(store.pulledOutVehicles) ? store.pulledOutVehicles : []
  return new Set(list.map((v) => normalizeId(v?.vehicleId)).filter((id) => id !== null))
})

const garageSlotsSkillLevel = ref(0)

const liftsFull = computed(() => {
  const list = store.pulledOutVehicles
  if (Array.isArray(list)) {
    return list.length >= store.maxPulledOutVehicles
  }
  return !!store.pulledOutVehicle
})

const canUpgradeGarageSlots = computed(() => garageSlotsSkillLevel.value < GARAGE_SLOTS_MAX_LEVEL)

const liftSlotsWarningText =
  "All garage slots are in use. Put away vehicle or upgrade skill tree"

const showLiftSlotsWarning = (vehicle) => {
  return (
    store.businessType === "racingTeam"
    && !isDeliveryPending(vehicle)
    && !isPulledOut(vehicle)
    && liftsFull.value
  )
}

const pullOutBlockedByLiftsFull = (vehicle) => showLiftSlotsWarning(vehicle)

const pullOutDisabledTitle = (vehicle) => {
  if (pullOutBlockedByFleetCooldown(vehicle)) {
    return vehicleDisabledTitle(vehicle, pullOutCooldownTitle(vehicle))
  }
  if (pullOutBlockedByLiftsFull(vehicle)) {
    return liftSlotsWarningText
  }
  return vehicleDisabledTitle(vehicle, "")
}

const refreshGarageSlotsSkillLevel = async () => {
  if (store.businessType !== "racingTeam" || !store.businessId) {
    garageSlotsSkillLevel.value = 0
    return
  }
  try {
    const level = await lua.career_modules_business_businessSkillTree.getNodeProgress(
      store.businessId,
      "qol",
      "garageSlots"
    )
    garageSlotsSkillLevel.value = Number(level) || 0
  } catch {
    garageSlotsSkillLevel.value = 0
  }
}

const goToGarageSlotsSkillTree = () => {
  store.switchView("skill-tree")
}

const handleAssessVehicle = async (v) => {
  const vid = v?.vehicleId ?? v?.id
  if (vid === null || vid === undefined) return
  await store.startRacingTeamVehicleAssessment(vid)
}

const formatAssessmentTime = (sec) => {
  const s = Number(sec) || 0
  const m = Math.floor(s / 60)
  const rem = s % 60
  return `${m}:${rem.toString().padStart(2, "0")}`
}

const isPulledOut = (vehicle) => {
  const vid = normalizeId(vehicle?.vehicleId)
  return vid !== null && pulledOutVehicleIds.value.has(vid)
}

const expandedKeyForVehicle = (vehicle) => String(normalizeId(vehicle?.vehicleId) ?? vehicle?.vehicleId ?? vehicle?.id ?? "")

const isExpanded = (vehicle) => expandedVehicleId.value === expandedKeyForVehicle(vehicle)

const toggleExpanded = (vehicle) => {
  const key = expandedKeyForVehicle(vehicle)
  expandedVehicleId.value = expandedVehicleId.value === key ? null : key
}

const handlePullOut = async (vehicle) => {
  if (pullOutBlockedByFleetCooldown(vehicle) || pullOutBlockedByLiftsFull(vehicle)) {
    return
  }
  await store.pullOutVehicle(vehicle.vehicleId)
}

const handlePutAway = async (vehicle) => {
  await store.putAwayVehicle(vehicle?.vehicleId)
}

const activateVehicleAndOpenView = async (vehicle, view) => {
  const vid = vehicle?.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  if (!isPulledOut(vehicle)) return
  await store.setActiveVehicleSelection(vid)
  await store.switchVehicleView(view)
}

const goToVehicleParts = async (vehicle) => {
  await activateVehicleAndOpenView(vehicle, "parts")
}

const goToVehicleTuning = async (vehicle) => {
  await activateVehicleAndOpenView(vehicle, "tuning")
}

const startVehiclePaint = async (vehicle) => {
  if (!isPulledOut(vehicle)) return
  const vid = vehicle?.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  await store.setActiveVehicleSelection(vid)
  await store.startVehiclePainting(vid)
}

const handleSell = (vehicle) => {
  if (!vehicle) return
  vehicleToSell.value = vehicle
  showAbandonModal.value = true
}

const openMaintenanceModal = (vehicle) => {
  if (!vehicle) return
  vehicleToMaintain.value = vehicle
  showMaintenanceModal.value = true
}

const openRepairModal = (vehicle) => {
  if (!vehicle) return
  vehicleToRepair.value = vehicle
  showRepairModal.value = true
}

const cancelRepair = () => {
  showRepairModal.value = false
  vehicleToRepair.value = null
}

const confirmRepair = async () => {
  const v = vehicleToRepair.value
  if (!v) return
  const result = await store.repairBusinessVehicle(v.vehicleId)
  if (result?.success) {
    await store.loadBusinessData(store.businessType, store.businessId)
    if (showMaintenanceModal.value && normalizeId(vehicleToMaintain.value?.vehicleId) === normalizeId(v?.vehicleId)) {
      await maintenanceModalComponentRef.value?.reload?.()
    }
    showRepairModal.value = false
    vehicleToRepair.value = null
  }
}

const closeMaintenanceModal = () => {
  vehicleToMaintain.value = null
}

const confirmAbandon = async () => {
  if (vehicleToSell.value) {
    await store.sellVehicle(vehicleToSell.value.vehicleId)
    showAbandonModal.value = false
    vehicleToSell.value = null
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  vehicleToSell.value = null
}

watch(showAbandonModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (abandonModalRef.value) {
        controllerNav.pushModal(abandonModalRef.value, cancelAbandon)
      }
    })
  } else if (abandonModalRef.value) {
    controllerNav.removeModal(abandonModalRef.value)
  }
})

watch(showRepairModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (repairModalRef.value) {
        controllerNav.pushModal(repairModalRef.value, cancelRepair)
      }
    })
  } else if (repairModalRef.value) {
    controllerNav.removeModal(repairModalRef.value)
  }
})

watch(
  () => [store.businessId, store.businessType],
  () => {
    refreshGarageSlotsSkillLevel()
  },
  { immediate: true }
)

onMounted(() => {
  bridge.events.on("businessSkillTree:onTreesUpdated", refreshGarageSlotsSkillLevel)
  fleetCooldownTickTimer = setInterval(() => {
    fleetCooldownTick.value++
    refreshPendingDeliveriesIfNeeded(Date.now())
  }, 1000)
})

onUnmounted(() => {
  bridge.events.off("businessSkillTree:onTreesUpdated", refreshGarageSlotsSkillLevel)
  if (fleetCooldownTickTimer) {
    clearInterval(fleetCooldownTickTimer)
    fleetCooldownTickTimer = null
  }
})
</script>

<style scoped lang="scss">
.vehicles-tab {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
}

.tab-header {
  .header-content {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 1em;
    flex-wrap: wrap;

    h2 {
      margin: 0 0 0.5em 0;
      color: rgba(245, 73, 0, 1);
      font-size: 1.5em;
    }

    p {
      margin: 0;
      color: rgba(255, 255, 255, 0.6);
    }
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 0.5em;
    margin-top: 0.5em;
    flex-wrap: wrap;
  }

  .header-action-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0.55em 1.1em;
    border: none;
    border-radius: 0.35em;
    font-size: 0.85em;
    font-weight: 600;
    color: #fff;
    background: rgba(245, 73, 0, 1);
    cursor: pointer;
    transition: background 0.2s, box-shadow 0.2s, opacity 0.2s;
    white-space: nowrap;
    text-transform: none;
    letter-spacing: 0.02em;

    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 0.92);
      box-shadow: 0 0 10px rgba(245, 73, 0, 0.35);
    }

    &:focus-visible {
      outline: 2px solid rgba(245, 73, 0, 0.75);
      outline-offset: 2px;
    }

    &:disabled,
    &[aria-disabled="true"] {
      opacity: 0.45;
      cursor: not-allowed;
      box-shadow: none;
    }
  }
}

.jobs-content {
  display: flex;
  flex-direction: column;
  gap: 2em;
}

.job-section {
  h3 {
    margin: 0 0 1em 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.25em;
    font-weight: 600;
  }
}

.vehicle-list {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
}

.vehicle-row {
  background: rgba(23, 23, 23, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.65em;
  overflow: clip;
}

.vehicle-row.expanded {
  border-color: rgba(245, 73, 0, 0.5);
}

.vehicle-row__header {
  width: 100%;
  background: transparent;
  color: inherit;
  border: none;
  padding: 0.8em 1em;
  cursor: pointer;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto auto;
  gap: 0.8em;
  align-items: center;
  text-align: left;
  box-sizing: border-box;

  &:focus {
    outline: none;
  }

  &:focus-visible {
    outline: 2px solid rgba(245, 73, 0, 0.75);
    outline-offset: 2px;
  }
}

.vehicle-row__identity {
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 0.75em;
}

.vehicle-row__thumb-wrap {
  position: relative;
  width: 5.4em;
  height: 3.2em;
  flex-shrink: 0;
}

.vehicle-row__thumb {
  width: 5.4em;
  height: 3.2em;
  object-fit: cover;
  border-radius: 0.4em;
  background: rgba(0, 0, 0, 0.35);
}

.vehicle-row__delivery-overlay {
  position: absolute;
  inset: 0;
  border-radius: 0.4em;
  background: rgba(0, 0, 0, 0.72);
  border: 1px solid rgba(245, 73, 0, 0.65);
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 0.2em;
  font-size: 0.62em;
  font-weight: 700;
  color: rgba(255, 215, 170, 0.98);
}

.vehicle-row__copy {
  min-width: 0;

  h4 {
    margin: 0;
    color: rgba(255, 255, 255, 0.95);
    font-size: 1em;
    font-weight: 600;
  }
}

.vehicle-row__stats {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.2em;
}

.vehicle-row__status {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.35em;
}

.vehicle-row__badge {
  font-size: 0.68em;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  padding: 0.25em 0.5em;
  border-radius: 4px;
  background: rgba(245, 73, 0, 0.85);
  color: #fff;
}

.vehicle-row__badge--idle {
  background: rgba(60, 120, 80, 0.85);
}

.vehicle-row__badge--delivery {
  background: rgba(220, 130, 20, 0.92);
}

.vehicle-row__bracket {
  font-weight: 600;
  color: rgba(255, 220, 180, 0.95);
}

.vehicle-row__dyno {
  font-size: 0.8em;
  color: #4ade80;
  background: rgba(34, 197, 94, 0.18);
  border: 1px solid rgba(34, 197, 94, 0.4);
  padding: 0.1em 0.4em;
  border-radius: 3px;
  margin-left: 0.5em;
}

.vehicle-row__dyno-required {
  font-size: 0.8em;
  color: #facc15;
  background: rgba(234, 179, 8, 0.18);
  border: 1px solid rgba(234, 179, 8, 0.4);
  padding: 0.1em 0.4em;
  border-radius: 3px;
  margin-left: 0.5em;
}

.vehicle-row__dyno-progress {
  font-size: 0.8em;
  color: #38bdf8;
  background: rgba(56, 189, 248, 0.18);
  border: 1px solid rgba(56, 189, 248, 0.4);
  padding: 0.1em 0.4em;
  border-radius: 3px;
  margin-left: 0.5em;
}

.vehicle-row__cooldown {
  font-size: 0.72em;
  color: rgba(255, 180, 120, 0.95);
  background: rgba(0, 0, 0, 0.6);
  border: 1px solid rgba(245, 73, 0, 0.45);
  border-radius: 0.25em;
  padding: 0.2em 0.4em;
}

.vehicle-row__chevron {
  width: 1em;
  height: 1em;
  color: rgba(255, 255, 255, 0.8);
}

.vehicle-row__expanded {
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  padding: 0.9em 1em 1em;
  display: flex;
  flex-direction: column;
  gap: 0.65em;
}

.vehicle-row__meta {
  margin: 0;
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.5);
}

.vehicle-row__meta--hp {
  font-weight: 600;
  color: rgba(255, 255, 255, 0.68);
}

.vehicle-row__hint {
  margin: 0;
  color: rgba(255, 185, 140, 0.9);
  font-size: 0.82em;
  font-weight: 500;
}

.vehicle-row__hint--warning {
  color: rgba(255, 200, 160, 0.95);
  line-height: 1.35;
}

.vehicle-row__actions {
  display: flex;
  gap: 0.5em;
  flex-wrap: wrap;

  .btn {
    border: none;
    border-radius: 0.35em;
    padding: 0.45em 0.75em;
    font-size: 0.8em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
  }

  .btn-primary {
    background: rgba(245, 73, 0, 1);
    color: #fff;
  }

  .btn-secondary {
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.95);
  }

  .btn-danger {
    background: rgba(239, 68, 68, 1);
    color: #fff;
  }

  .btn:disabled,
  .btn[disabled] {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.empty-state {
  padding: 3em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
}

.modal-content {
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 1em 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
  }

  p {
    margin: 0 0 2em 0;
    color: rgba(255, 255, 255, 0.8);
    font-size: 1em;
    line-height: 1.5;
  }

  .modal-buttons {
    display: flex;
    gap: 1em;
    justify-content: flex-end;
  }

  .btn {
    padding: 0.75em 1.5em;
    border: none;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;

    &.btn-secondary {
      background: rgba(255, 255, 255, 0.1);
      color: rgba(255, 255, 255, 0.9);

      &:hover {
        background: rgba(255, 255, 255, 0.15);
      }
    }

    &.btn-danger {
      background: rgba(239, 68, 68, 1);
      color: white;

      &:hover {
        background: rgba(239, 68, 68, 0.9);
        box-shadow: 0 0 10px rgba(239, 68, 68, 0.4);
      }
    }

    &.btn-primary {
      background: rgba(245, 73, 0, 1);
      color: white;

      &:hover {
        background: rgba(245, 73, 0, 0.92);
      }
    }
  }
}

.modal-content--repair {
  border-color: rgba(245, 73, 0, 0.55);
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;

  .modal-content {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .modal-content {
    transform: scale(0.95);
    opacity: 0;
  }
}
</style>
