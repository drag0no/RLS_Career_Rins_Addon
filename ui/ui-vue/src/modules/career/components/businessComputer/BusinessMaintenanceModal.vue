<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div
        v-if="open"
        class="modal-overlay"
        @click.self.stop="close"
        @mousedown.self.stop="close"
      >
        <div class="modal-content modal-content--maintenance" ref="modalRef">
          <h2>Vehicle maintenance</h2>
          <p class="maintenance-modal__subtitle">{{ vehicleTitle }}</p>
          <div v-if="errorMessage" class="maintenance-modal__error">{{ errorMessage }}</div>
          <div v-else-if="loading" class="maintenance-modal__loading">Loading maintenance data...</div>
          <div v-else class="maintenance-modal__content">
            <div v-for="category in categories" :key="category.name" class="maintenance-category">
              <h3>{{ category.label }}</h3>
              <div class="maintenance-rows">
                <div
                  v-for="row in category.rows || []"
                  :key="`${row.category}:${row.item}`"
                  class="maintenance-row"
                >
                  <div class="maintenance-row__copy">
                    <strong>{{ row.label }}</strong>
                    <span v-if="row.isRevealed">{{ row.revealedPercent }}% health</span>
                    <span v-else>Unknown condition</span>
                  </div>
                  <div class="maintenance-row__actions">
                    <button
                      class="btn btn-secondary"
                      data-focusable
                      :disabled="isBusy(row, 'check')"
                      @click.stop="runCheck(row)"
                      @mousedown.stop
                    >
                      Check
                    </button>
                    <button
                      class="btn btn-primary"
                      data-focusable
                      :disabled="!row.canAffordService || isBusy(row, 'service')"
                      @click.stop="runService(row)"
                      @mousedown.stop
                    >
                      {{ row.actionLabel }} ({{ formatMoney(row.servicePrice) }})
                    </button>
                  </div>
                </div>
              </div>
            </div>

            <div class="maintenance-category tire-category">
              <h3>Tires</h3>
              <p v-if="tireShop?.provider" class="tire-provider">
                Using {{ tireShop.provider.name }} {{ tireShop.provider.version || "" }}
              </p>
              <p v-if="!tireShop?.available" class="tire-provider">
                {{ tireShop?.message || "Tire service is unavailable." }}
              </p>
              <template v-else-if="!tireShop.inspected">
                <div class="tire-check-row">
                  <span>Tire condition has not been inspected.</span>
                  <button
                    class="btn btn-primary"
                    data-focusable
                    :disabled="busyActionKey === 'tires:check'"
                    @click.stop="runTireCheck"
                    @mousedown.stop
                  >Check All Tires — Free</button>
                </div>
              </template>
              <template v-else>
                <div class="maintenance-rows">
                  <div v-for="axle in tireShop.axles || []" :key="axle.id" class="maintenance-row">
                    <div class="maintenance-row__copy">
                      <strong>{{ axle.label }} · {{ axle.tireName }}</strong>
                      <span :class="{ 'tire-flat': axle.flat }">
                        {{ axle.flat ? "Flat/popped" : `${axle.remainingPercent}% tread` }} ·
                        {{ formatMoney(axle.perTirePrice) }} each
                      </span>
                      <span>{{ (axle.wheelStates || []).map(wheel => `${wheel.name}: ${wheel.flat ? "FLAT" : `${wheel.remainingPercent}%`}`).join(" · ") }}</span>
                    </div>
                    <button
                      class="btn btn-secondary"
                      data-focusable
                      :disabled="Boolean(pendingTireAxles.length)"
                      @click.stop="beginTireCheckout([axle.id])"
                      @mousedown.stop
                    >Replace ({{ formatMoney(axle.subtotal) }})</button>
                  </div>
                </div>
                <div class="tire-replace-all">
                  <button
                    class="btn btn-primary"
                    data-focusable
                    :disabled="Boolean(pendingTireAxles.length)"
                    @click.stop="beginTireCheckout((tireShop.axles || []).map(axle => axle.id))"
                    @mousedown.stop
                  >Replace All ({{ formatMoney(tireShop.replaceAllSubtotal) }})</button>
                </div>
              </template>

              <div v-if="pendingTireAxles.length" class="tire-confirm">
                <strong>Confirm fresh tire purchase</strong>
                <span v-for="axle in selectedTireGroups" :key="axle.id">
                  {{ axle.label }} — {{ formatMoney(axle.subtotal) }}
                </span>
                <strong>Total: {{ formatMoney(selectedTireTotal) }}</strong>
                <div class="tire-confirm-actions">
                  <button class="btn btn-secondary" data-focusable @click.stop="cancelTireCheckout" @mousedown.stop>Cancel</button>
                  <button
                    class="btn btn-primary"
                    data-focusable
                    :disabled="busyActionKey === 'tires:checkout'"
                    @click.stop="confirmTireCheckout"
                    @mousedown.stop
                  >Buy and Install</button>
                </div>
              </div>
            </div>
          </div>
          <div class="modal-buttons">
            <button class="btn btn-secondary" data-focusable @click.stop="close" @mousedown.stop="close">
              Close
            </button>
          </div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { ref, computed, watch, inject, nextTick } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const props = defineProps({
  open: { type: Boolean, default: false },
  vehicle: { type: Object, default: null },
})

const emit = defineEmits(["update:open", "close"])

const store = useBusinessComputerStore()
const controllerNav = inject("controllerNav", null)
const modalRef = ref(null)
const loading = ref(false)
const errorMessage = ref("")
const uiData = ref(null)
const busyActionKey = ref("")
const pendingTireAxles = ref([])

const moneyFormat = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 })

const vehicleTitle = computed(() => {
  const v = props.vehicle
  if (!v) return "Vehicle"
  return v.vehicleName || v.name || `Vehicle #${v.vehicleId ?? v.id ?? ""}`
})

const categories = computed(() => uiData.value?.categories || [])
const tireShop = computed(() => uiData.value?.tireShop || null)
const selectedTireGroups = computed(() => {
  const selected = new Set(pendingTireAxles.value)
  return (tireShop.value?.axles || []).filter(axle => selected.has(axle.id))
})
const selectedTireTotal = computed(() =>
  selectedTireGroups.value.reduce((total, axle) => total + (Number(axle.subtotal) || 0), 0)
)

const formatMoney = (value) => {
  const n = Number(value)
  return moneyFormat.format(Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0)
}

const busyKey = (row, action) => `${row?.category || ""}:${row?.item || ""}:${action}`
const isBusy = (row, action) => busyActionKey.value === busyKey(row, action)

const loadData = async () => {
  const vehicle = props.vehicle
  if (!vehicle) {
    errorMessage.value = "No vehicle selected."
    uiData.value = null
    return
  }
  loading.value = true
  errorMessage.value = ""
  try {
    const result = await store.getBusinessMaintenanceUiData(vehicle.vehicleId)
    if (!result?.enabled) {
      errorMessage.value = result?.errorMessage || "Maintenance is unavailable for this vehicle."
      uiData.value = null
      return
    }
    uiData.value = result
  } catch {
    errorMessage.value = "Failed to load maintenance data."
    uiData.value = null
  } finally {
    loading.value = false
  }
}

const runCheck = async (row) => {
  const v = props.vehicle
  if (!v || !row) return
  busyActionKey.value = busyKey(row, "check")
  try {
    const result = await store.startBusinessMaintenanceCheck(v.vehicleId, row.category, row.item)
    if (result?.ok) {
      await loadData()
    }
  } finally {
    busyActionKey.value = ""
  }
}

const runService = async (row) => {
  const v = props.vehicle
  if (!v || !row) return
  busyActionKey.value = busyKey(row, "service")
  try {
    const result = await store.startBusinessMaintenanceService(v.vehicleId, row.category, row.item)
    if (result?.ok) {
      await loadData()
    }
  } finally {
    busyActionKey.value = ""
  }
}

const runTireCheck = async () => {
  const v = props.vehicle
  if (!v) return
  busyActionKey.value = "tires:check"
  try {
    const result = await store.inspectBusinessVehicleTires(v.vehicleId)
    if (result?.ok) await loadData()
  } finally {
    busyActionKey.value = ""
  }
}

const beginTireCheckout = axleIds => {
  pendingTireAxles.value = [...axleIds]
}

const cancelTireCheckout = () => {
  pendingTireAxles.value = []
}

const confirmTireCheckout = async () => {
  const v = props.vehicle
  if (!v) return
  busyActionKey.value = "tires:checkout"
  try {
    const result = await store.checkoutBusinessVehicleTires(
      v.vehicleId, pendingTireAxles.value, tireShop.value?.quoteRevision
    )
    if (result?.ok) {
      pendingTireAxles.value = []
      await loadData()
    } else if (result?.staleQuote) {
      await loadData()
    }
  } finally {
    busyActionKey.value = ""
  }
}

const close = () => {
  emit("update:open", false)
  emit("close")
}

watch(
  () => props.open,
  async (isOpen) => {
    if (isOpen) {
      await loadData()
    } else {
      uiData.value = null
      errorMessage.value = ""
      busyActionKey.value = ""
      pendingTireAxles.value = []
    }
  }
)

watch(
  () => props.vehicle?.vehicleId,
  async () => {
    if (props.open) {
      await loadData()
    }
  }
)

watch(
  () => props.open,
  (isOpen) => {
    if (!controllerNav) return
    if (isOpen) {
      nextTick(() => {
        if (modalRef.value) {
          controllerNav.pushModal(modalRef.value, close)
        }
      })
    } else if (modalRef.value) {
      controllerNav.removeModal(modalRef.value)
    }
  }
)

defineExpose({ reload: loadData })
</script>

<style scoped lang="scss">
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
}

.modal-content--maintenance {
  max-width: 48em;
}

.maintenance-modal__subtitle {
  margin-top: -0.5em;
  margin-bottom: 1em;
  color: rgba(255, 255, 255, 0.7);
}

.maintenance-modal__error {
  margin-bottom: 1em;
  padding: 0.6em 0.8em;
  border-radius: 0.35em;
  background: rgba(140, 40, 40, 0.45);
  color: rgba(255, 220, 220, 0.95);
  border: 1px solid rgba(220, 90, 90, 0.55);
}

.maintenance-modal__loading {
  color: rgba(255, 255, 255, 0.75);
}

.maintenance-modal__content {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
  max-height: 58vh;
  overflow-y: auto;
  padding-right: 0.3em;
}

.maintenance-category {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 0.5em;
  padding: 0.7em;

  h3 {
    margin: 0 0 0.6em 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1em;
  }
}

.maintenance-rows {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.maintenance-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.8em;
  padding: 0.55em 0.65em;
  border-radius: 0.4em;
  background: rgba(255, 255, 255, 0.04);
}

.maintenance-row__copy {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
  min-width: 0;

  strong {
    font-size: 0.92em;
    color: rgba(255, 255, 255, 0.94);
  }

  span {
    font-size: 0.78em;
    color: rgba(255, 255, 255, 0.62);
  }
}

.maintenance-row__actions {
  display: flex;
  gap: 0.45em;
  flex-wrap: wrap;
}

.tire-provider {
  margin: 0 0 0.7em;
  color: rgba(255, 255, 255, 0.66);
  font-size: 0.8em;
}

.tire-check-row,
.tire-replace-all,
.tire-confirm-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.8em;
}

.tire-replace-all {
  justify-content: flex-end;
  margin-top: 0.7em;
}

.tire-flat { color: #ff7777 !important; }

.tire-confirm {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  margin-top: 0.8em;
  padding: 0.7em;
  border: 1px solid rgba(245, 73, 0, 0.55);
  border-radius: 0.4em;
  background: rgba(245, 73, 0, 0.08);
}

.tire-confirm-actions { justify-content: flex-end; }

.modal-buttons {
  display: flex;
  gap: 1em;
  justify-content: flex-end;
  margin-top: 1.5em;
}

.btn {
  padding: 0.75em 1.5em;
  border: none;
  border-radius: 0.25em;
  font-size: 1em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
}

.btn-primary {
  background: #F54900;
  color: white;

  &:hover {
    background: #ff5a14;
  }
}

.btn-secondary {
  background: rgba(255, 255, 255, 0.1);
  color: white;
  border: 1px solid rgba(255, 255, 255, 0.2);

  &:hover {
    background: rgba(255, 255, 255, 0.15);
  }
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
